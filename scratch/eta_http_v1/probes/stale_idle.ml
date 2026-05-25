(* Scratch-only R5 probe for real h1 stale-idle pool behavior. *)

let fail msg =
  Printf.eprintf "eta_http_r5_stale_idle verdict=FAIL detail=%S\n%!" msg;
  exit 1

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> fail "expected TCP listening socket"

let authenticator () =
  match Ca_certs.authenticator () with
  | Ok authenticator -> authenticator
  | Error (`Msg msg) -> fail msg

let read_headers flow =
  let reader = Eio.Buf_read.of_flow ~initial_size:256 ~max_size:4096 flow in
  let rec loop count =
    match Eio.Buf_read.line reader with
    | "" -> count
    | _ -> loop (count + 1)
  in
  loop 0

let serve_one flow index body =
  let header_lines = read_headers flow in
  let response =
    Printf.sprintf
      "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: keep-alive\r\n\r\n%s"
      (String.length body) body
  in
  Eio.Flow.copy_string response flow;
  Eio.Flow.close flow;
  Printf.printf
    "eta_http_r5_stale_idle_server connection=%d request_header_lines=%d closed_after_response=true\n%!"
    index header_lines

let start_stale_idle_server ~sw ~net =
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:2 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let done_p, done_u = Eio.Promise.create () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      let result =
        try
          List.iteri
            (fun index body ->
              Eio.Switch.run @@ fun conn_sw ->
              let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
              serve_one flow (index + 1) body)
            [ "one"; "two" ];
          Ok ()
        with exn -> Error (Printexc.to_string exn)
      in
      ignore (Eio.Promise.try_resolve done_u result);
      `Stop_daemon);
  (port, done_p)

let make_timeout_error url =
  Http.Error.make ~method_:"GET" ~uri:url
    (Total_request_timeout { timeout_ms = Some 5_000 })

let request_once rt pool url =
  let request : Http.H1.Client.request =
    {
      method_ = "GET";
      url = Http.Core.Url.of_string url;
      headers = [ ("User-Agent", "eta-http-r5-stale-idle") ];
      body = Http.H1.Client.Empty;
    }
  in
  let effect =
    Http.H1.Client.request_with_pool pool request
    |> Eta.Effect.bind (fun (response : Http.H1.Client.response) ->
           Http.Body.Stream.read_all response.body
           |> Eta.Effect.map (fun body -> (response.status, body)))
    |> Eta.Effect.timeout_as (Eta.Duration.seconds 5)
         ~on_timeout:(make_timeout_error url)
  in
  match Eta.Runtime.run rt effect with
  | Eta.Exit.Ok (status, body) -> (status, Bytes.to_string body)
  | Eta.Exit.Error cause ->
      Format.asprintf "%a" (Eta.Cause.pp Http.Error.pp) cause |> fail

let require label cond detail = if not cond then fail (label ^ ": " ^ detail)

let run env =
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let port, server_done = start_stale_idle_server ~sw ~net in
  let url = Printf.sprintf "http://127.0.0.1:%d/r5-stale-idle" port in
  let pool =
    Http.H1.Client.make_pool ~max_size:1 ~sw ~net
      ~authenticator:(authenticator ())
      (Http.Core.Url.of_string url)
    |> Eta.Runtime.run rt
  in
  let pool =
    match pool with
    | Eta.Exit.Ok pool -> pool
    | Eta.Exit.Error cause ->
        Format.asprintf "%a" (Eta.Cause.pp Http.Error.pp) cause |> fail
  in
  let first_status, first_body = request_once rt pool url in
  let after_first = Http.H1.Client.pool_stats pool in
  let second_status, second_body = request_once rt pool url in
  let after_second = Http.H1.Client.pool_stats pool in
  let server_result = Eio.Promise.await server_done in
  require "first status" (first_status = 200)
    (Printf.sprintf "got %d" first_status);
  require "first body" (String.equal first_body "one")
    (Printf.sprintf "got %S" first_body);
  require "first idle" (after_first.idle = 1)
    (Printf.sprintf "idle=%d" after_first.idle);
  require "second status" (second_status = 200)
    (Printf.sprintf "got %d" second_status);
  require "second body" (String.equal second_body "two")
    (Printf.sprintf "got %S" second_body);
  require "stale idle rejected" (after_second.health_rejected = 1)
    (Printf.sprintf "health_rejected=%d" after_second.health_rejected);
  require "replacement opened" (after_second.opened = 2)
    (Printf.sprintf "opened=%d" after_second.opened);
  require "stale connection closed" (after_second.closed = 1)
    (Printf.sprintf "closed=%d" after_second.closed);
  (match server_result with Ok () -> () | Error detail -> fail detail);
  Printf.printf
    "eta_http_r5_stale_idle verdict=PASS first_body=%s second_body=%s opened=%d closed=%d health_rejected=%d idle_after_first=%d idle_after_second=%d protocol=h1 peer=loopback_close_after_response\n%!"
    first_body second_body after_second.opened after_second.closed
    after_second.health_rejected after_first.idle after_second.idle

let () = Eio_main.run run
