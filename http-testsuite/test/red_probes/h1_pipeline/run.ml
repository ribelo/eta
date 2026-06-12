(* Red probes for HTTP/1.1 pipelining / keep-alive state machine.
   These probes intentionally look for connection-reuse bugs in eta_http_eio's
   H1 server connection loop.  They exit 0 even when they find things. *)

open Eta_http_testsuite
open Eio.Std

type read_result =
  | Closed of string
  | Timed_out of string

type outcome = {
  statuses : int list;
  closed : bool;
}

type probe_status =
  | Pass
  | Fail
  | Hang
  | Crash
  | Policy_gap

let status_to_string = function
  | Pass -> "PASS"
  | Fail -> "FAIL"
  | Hang -> "HANG"
  | Crash -> "CRASH"
  | Policy_gap -> "POLICY_GAP"

let tcp_port = Adversarial.tcp_port

let statuses_of data =
  let len = String.length data in
  let rec scan i acc =
    if i + 12 > len then List.rev acc
    else
      let prefix = String.sub data i 7 in
      if String.equal prefix "HTTP/1." then
        let code =
          try int_of_string (String.sub data (i + 9) 3) with _ -> 0
        in
        scan (i + 1) (code :: acc)
      else scan (i + 1) acc
  in
  scan 0 []

let string_of_statuses statuses =
  "[" ^ String.concat ";" (List.map string_of_int statuses) ^ "]"

let read_responses ~clock ~deadline_sec flow =
  let buf = Buffer.create 256 in
  let scratch = Cstruct.create 4096 in
  let rec read_loop () =
    match Eio.Flow.single_read flow scratch with
    | 0 -> Closed (Buffer.contents buf)
    | n ->
        Buffer.add_string buf
          (Cstruct.to_string (Cstruct.sub scratch 0 n));
        read_loop ()
    | exception End_of_file -> Closed (Buffer.contents buf)
    | exception Eio.Cancel.Cancelled _ -> Timed_out (Buffer.contents buf)
  in
  let timeout_fiber () =
    Eio.Time.sleep clock deadline_sec;
    Timed_out (Buffer.contents buf)
  in
  Eio.Fiber.first read_loop timeout_fiber

let h1_config ?handler_timeout ?unread_body_policy ?request_body_timeout () =
  let server =
    {
      Eta_http.Server.Config.default with
      unread_body_policy =
        Option.value unread_body_policy
          ~default:Eta_http.Server.Config.default.unread_body_policy;
      enable_otel = false;
      timeouts =
        {
          Eta_http.Server.Config.default.timeouts with
          handler_timeout =
            Option.value handler_timeout
              ~default:Eta_http.Server.Config.default.timeouts.handler_timeout;
          request_body_timeout =
            Option.value request_body_timeout
              ~default:Eta_http.Server.Config.default.timeouts.request_body_timeout;
        };
    }
  in
  {
    Eta_http_eio.Server.Config.default with
    backlog = 1;
    max_connections = 8;
    server;
  }

let simple_handler _request =
  Eta.Effect.pure (Eta_http.Server.Response.text "ok\n")

let boom_handler request =
  match request.Eta_http.Server.Request.path with
  | "/boom" -> failwith "boom"
  | _ -> Eta.Effect.pure (Eta_http.Server.Response.text "ok\n")

let slow_handler clock request =
  match request.Eta_http.Server.Request.path with
  | "/slow" ->
      Eio.Time.sleep clock 0.5;
      Eta.Effect.pure (Eta_http.Server.Response.text "slow\n")
  | _ -> Eta.Effect.pure (Eta_http.Server.Response.text "ok\n")

let run_h1_client ?config ~env ~handler ~input ~deadline_sec () =
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let config = Option.value config ~default:(h1_config ()) in
  let server =
    Eta_http_eio.Server.start_h1_on_socket ~sw ~clock ~config ~socket handler
  in
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  Fun.protect
    ~finally:(fun () ->
      (try Eio.Flow.shutdown flow `All with _ -> ());
      Eta_http_eio.Server.shutdown server Immediate)
    (fun () ->
      Eio.Flow.copy_string input flow;
      match read_responses ~clock ~deadline_sec flow with
      | Closed data -> { statuses = statuses_of data; closed = true }
      | Timed_out data -> { statuses = statuses_of data; closed = false })

(* -------------------------------------------------------------------------- *)
(* Probe implementations                                                       *)
(* -------------------------------------------------------------------------- *)

let probe_pipeline_two_ok env =
  let input =
    "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n"
    ^ "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n"
  in
  let outcome =
    run_h1_client ~env ~handler:simple_handler ~input ~deadline_sec:1.0 ()
  in
  match outcome with
  | { statuses = [ 200; 200 ]; closed = false } ->
      (Pass, "two 200 responses, connection kept alive")
  | { statuses = [ 200; 200 ]; closed = true } ->
      (Fail, "two 200 responses but connection closed")
  | { statuses = []; closed = false } -> (Hang, "no response within deadline")
  | { statuses; closed } ->
      (Fail,
       Printf.sprintf "statuses=%s closed=%b"
         (string_of_statuses statuses) closed)

let probe_malformed_then_valid env =
  (* Missing Host on HTTP/1.1 is a 400.  The connection should close so the
     pipelined valid request is not processed. *)
  let input =
    "GET / HTTP/1.1\r\n\r\n"
    ^ "GET /ok HTTP/1.1\r\nHost: example.test\r\n\r\n"
  in
  let outcome =
    run_h1_client ~env ~handler:simple_handler ~input ~deadline_sec:1.0 ()
  in
  match outcome with
  | { statuses = [ 400 ]; closed = true } ->
      (Pass, "malformed request rejected and connection closed")
  | { statuses = 400 :: (_ :: _ as rest); _ } ->
      (Fail,
       Printf.sprintf "malformed request did not close connection; also got %s"
         (string_of_statuses rest))
  | { statuses = [ 400 ]; closed = false } ->
      (Policy_gap, "400 sent but connection left open")
  | { statuses = []; closed = false } -> (Hang, "no response within deadline")
  | { statuses; closed } ->
      (Fail,
       Printf.sprintf "statuses=%s closed=%b"
         (string_of_statuses statuses) closed)

let probe_unread_body_drain_small env =
  let config =
    h1_config ~unread_body_policy:(Eta_http.Server.Config.Drain_up_to 64) ()
  in
  let input =
    "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 10\r\n\r\n"
    ^ "0123456789"
    ^ "GET /ok HTTP/1.1\r\nHost: example.test\r\n\r\n"
  in
  let outcome =
    run_h1_client ~env ~config ~handler:simple_handler ~input ~deadline_sec:1.5 ()
  in
  match outcome with
  | { statuses = [ 200; 200 ]; closed = false } ->
      (Pass, "small unread body drained and connection reused")
  | { statuses = [ 200 ]; closed = true } ->
      (Fail, "small unread body caused connection close")
  | { statuses = []; closed = false } -> (Hang, "no response within deadline")
  | { statuses; closed } ->
      (Fail,
       Printf.sprintf "statuses=%s closed=%b"
         (string_of_statuses statuses) closed)

let probe_unread_body_drain_large env =
  let config =
    h1_config ~unread_body_policy:(Eta_http.Server.Config.Drain_up_to 64) ()
  in
  let body = String.make 1000 'x' in
  let input =
    "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 1000\r\n\r\n"
    ^ body
    ^ "GET /ok HTTP/1.1\r\nHost: example.test\r\n\r\n"
  in
  let outcome =
    run_h1_client ~env ~config ~handler:simple_handler ~input ~deadline_sec:2.0 ()
  in
  match outcome with
  | { statuses = [ 200 ]; closed = true } ->
      (Pass, "large unread body caused connection close")
  | { statuses = [ 200; 200 ]; _ }
  | { statuses = 200 :: 200 :: _; _ } ->
      (Fail, "large unread body did not prevent request smuggling")
  | { statuses = [ 200 ]; closed = false } ->
      (Policy_gap, "large unread body left connection open")
  | { statuses = []; closed = false } -> (Hang, "no response within deadline")
  | { statuses; closed } ->
      (Fail,
       Printf.sprintf "statuses=%s closed=%b"
         (string_of_statuses statuses) closed)

let probe_unread_body_reset env =
  (* Reset is the default: any unread fixed body must force connection close. *)
  let config = h1_config ~unread_body_policy:Eta_http.Server.Config.Reset () in
  let input =
    "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 10\r\n\r\n"
    ^ "0123456789"
    ^ "GET /ok HTTP/1.1\r\nHost: example.test\r\n\r\n"
  in
  let outcome =
    run_h1_client ~env ~config ~handler:simple_handler ~input ~deadline_sec:1.5 ()
  in
  match outcome with
  | { statuses = [ 200 ]; closed = true } ->
      (Pass, "Reset policy closed connection with unread body")
  | { statuses = [ 200; 200 ]; _ } ->
      (Fail, "Reset policy ignored and connection reused")
  | { statuses = [ 200 ]; closed = false } ->
      (Policy_gap, "Reset policy: connection left open")
  | { statuses = []; closed = false } -> (Hang, "no response within deadline")
  | { statuses; closed } ->
      (Fail,
       Printf.sprintf "statuses=%s closed=%b"
         (string_of_statuses statuses) closed)

let probe_handler_exception_then_valid env =
  let input =
    "GET /boom HTTP/1.1\r\nHost: example.test\r\n\r\n"
    ^ "GET /ok HTTP/1.1\r\nHost: example.test\r\n\r\n"
  in
  let outcome =
    run_h1_client ~env ~handler:boom_handler ~input ~deadline_sec:1.0 ()
  in
  match outcome with
  | { statuses = [ 500 ]; closed = true } ->
      (Pass, "handler exception produced 500 and closed connection")
  | { statuses = 500 :: 200 :: _; _ } ->
      (Fail, "handler exception did not prevent connection reuse")
  | { statuses = [ 500 ]; closed = false } ->
      (Policy_gap, "handler exception: 500 but connection kept open")
  | { statuses = []; closed = false } -> (Hang, "no response within deadline")
  | { statuses; closed } ->
      (Fail,
       Printf.sprintf "statuses=%s closed=%b"
         (string_of_statuses statuses) closed)

let probe_handler_timeout_then_valid env =
  let config =
    h1_config ~handler_timeout:(Some (Eta.Duration.ms 100)) ()
  in
  let input =
    "GET /slow HTTP/1.1\r\nHost: example.test\r\n\r\n"
    ^ "GET /ok HTTP/1.1\r\nHost: example.test\r\n\r\n"
  in
  let outcome =
    run_h1_client ~env ~config ~handler:(slow_handler (Eio.Stdenv.clock env))
      ~input ~deadline_sec:2.0 ()
  in
  match outcome with
  | { statuses = [ 503 ]; closed = true } ->
      (Pass, "handler timeout produced 503 and closed connection")
  | { statuses = 503 :: 200 :: _; _ } ->
      (Fail, "handler timeout did not prevent connection reuse")
  | { statuses = [ 503 ]; closed = false } ->
      (Policy_gap, "handler timeout: 503 but connection kept open")
  | { statuses = []; closed = false } -> (Hang, "no response within deadline")
  | { statuses; closed } ->
      (Fail,
       Printf.sprintf "statuses=%s closed=%b"
         (string_of_statuses statuses) closed)

let probe_partial_body_then_request env =
  (* Content-Length says 100 bytes but only 10 are sent, followed immediately
     by the next request.  The server must not process the second request. *)
  let input =
    "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 100\r\n\r\n"
    ^ "0123456789"
    ^ "GET /ok HTTP/1.1\r\nHost: example.test\r\n\r\n"
  in
  let outcome =
    run_h1_client ~env ~handler:simple_handler ~input ~deadline_sec:1.5 ()
  in
  match outcome with
  | { statuses = [ 200 ]; closed = true } ->
      (Pass, "partial body caused connection close, second request ignored")
  | { statuses = [ 200; 200 ]; _ } ->
      (Fail, "partial body did not prevent second request")
  | { statuses = [ 200 ]; closed = false } ->
      (Policy_gap, "partial body: connection left open")
  | { statuses = []; closed = false } -> (Hang, "no response within deadline")
  | { statuses; closed } ->
      (Fail,
       Printf.sprintf "statuses=%s closed=%b"
         (string_of_statuses statuses) closed)

let probes =
  [
    ("pipeline_two_ok", probe_pipeline_two_ok);
    ("malformed_then_valid", probe_malformed_then_valid);
    ("unread_body_drain_small", probe_unread_body_drain_small);
    ("unread_body_drain_large", probe_unread_body_drain_large);
    ("unread_body_reset", probe_unread_body_reset);
    ("handler_exception_then_valid", probe_handler_exception_then_valid);
    ("handler_timeout_then_valid", probe_handler_timeout_then_valid);
    ("partial_body_then_request", probe_partial_body_then_request);
  ]

let run_probe env (name, f) =
  try
    let status, detail = f env in
    Printf.printf "probe %s %s %s\n%!" name (status_to_string status) detail
  with exn ->
    Printf.printf "probe %s CRASH %s\n%!" name (Printexc.to_string exn)

let () =
  Eio_main.run @@ fun env ->
  List.iter (run_probe env) probes;
  Printf.printf "h1_pipeline done\n%!"
