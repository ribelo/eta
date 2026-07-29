module E = Eta.Effect
module R = Eta_ai_openai.Realtime
module T = Eta_ai_openai_realtime_eio

type read_action = Return of string | Await : unit Eio.Promise.t -> read_action

type scripted_flow = {
  reads : read_action Stdlib.Queue.t;
  mutable pending : string option;
  mutable writes : int;
  fail_write : int option;
  mutable closed : int;
}

module Scripted_flow = struct
  type t = scripted_flow

  let read_methods = []

  let rec next_chunk t =
    match t.pending with
    | Some chunk -> chunk
    | None -> (
        match Stdlib.Queue.take_opt t.reads with
        | Some (Return chunk) -> chunk
        | Some (Await promise) ->
            Eio.Promise.await promise;
            raise End_of_file
        | None -> raise End_of_file)

  let single_read t dst =
    let chunk = next_chunk t in
    let len = min (String.length chunk) (Cstruct.length dst) in
    Cstruct.blit_from_string chunk 0 dst 0 len;
    if len = String.length chunk then t.pending <- None
    else t.pending <- Some (String.sub chunk len (String.length chunk - len));
    len

  let single_write t bufs =
    t.writes <- t.writes + 1;
    if t.fail_write = Some t.writes then failwith "scripted write failure";
    Cstruct.lenv bufs

  let copy t ~src = Eio.Flow.Pi.simple_copy ~single_write t ~src
  let shutdown _ _ = ()
  let close t = t.closed <- t.closed + 1
end

let switching_response key =
  "HTTP/1.1 101 Switching Protocols\r\n"
  ^ "Upgrade: websocket\r\n"
  ^ "Connection: Upgrade\r\n"
  ^ "Sec-WebSocket-Accept: "
  ^ Eta_http_ws.Codec.accept_key ~sha1:Eta_http_tls_openssl.sha1 key
  ^ "\r\n\r\n"

let scripted_flow ?fail_write key =
  let never, _ = Eio.Promise.create () in
  let reads = Stdlib.Queue.create () in
  Stdlib.Queue.push (Return (switching_response key)) reads;
  Stdlib.Queue.push (Await never) reads;
  let state =
    {
      reads;
      pending = None;
      writes = 0;
      fail_write;
      closed = 0;
    }
  in
  let flow : Eta_http_eio.Ws.Client.flow =
    Eio.Resource.T
      ( state,
        Eio.Resource.handler
          (Eio.Resource.H (Eio.Resource.Close, Scripted_flow.close)
          :: Eio.Resource.bindings
               (Eio.Flow.Pi.two_way (module Scripted_flow))) )
  in
  (state, flow)

let with_runtime f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  f sw rt

let connect_effect ~key ~sw ~flow =
  T.connect_session_on_flow ~key ~sw ~flow
    ~api_key:(Eta_ai.api_key "sk-test")
    (Eta_http.Core.Url.of_string "http://api.openai.test/v1/realtime")
    (R.session ~model:"gpt-realtime-2" ~instructions:"brief" ())

let test_initialization_failure_closes_connection () =
  with_runtime @@ fun sw rt ->
  let key = "dGhlIHNhbXBsZSBub25jZQ==" in
  let state, flow = scripted_flow ~fail_write:2 key in
  (match Eta.Runtime.run rt (connect_effect ~key ~sw ~flow) with
  | Eta.Exit.Error _ -> ()
  | Eta.Exit.Ok _ -> Alcotest.fail "expected session initialization failure");
  Alcotest.(check bool) "flow closed after failure" true (state.closed > 0)

let tests =
  [
    ( "realtime-eio-transport",
      [
        Alcotest.test_case "initialization failure closes connection" `Quick
          test_initialization_failure_closes_connection;
      ] );
  ]
