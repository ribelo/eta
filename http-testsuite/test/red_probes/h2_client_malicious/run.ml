(* h2_client_malicious: HTTP/2 client-side adversarial probes.

   Each probe starts a malicious in-process HTTP/2 server and drives the
   eta_http_eio H2 client with invalid frame ordering, pathological continuation
   chains, flow-control edge cases, GOAWAY/RST_STREAM races, push promise, and
   slow responses.  A hang past the deadline is recorded as a finding.  The
   runner always exits 0. *)

open Eio.Std
open Eta_http_testsuite

(* ---------------------------------------------------------------------------
   Status reporting
   --------------------------------------------------------------------------- *)

type status = PASS | FAIL | HANG | CRASH | POLICY_GAP

let string_of_status = function
  | PASS -> "PASS"
  | FAIL -> "FAIL"
  | HANG -> "HANG"
  | CRASH -> "CRASH"
  | POLICY_GAP -> "POLICY_GAP"

let print_probe name status detail =
  Printf.printf "probe %s %s%s\n%!" name (string_of_status status)
    (match detail with None -> "" | Some d -> " " ^ d)

type outcome =
  | Ok of string
  | Eta_error of string
  | Hang of string
  | Crash of string

type expectation =
  | Expect_response
  | Expect_error
  | Expect_timeout

let is_timeout_error msg = String.starts_with ~prefix:"Fail(eta-http error=Total_request_timeout" msg

let is_protocol_error msg =
  String.starts_with ~prefix:"Fail(eta-http error=Connection_protocol_violation" msg
  || String.starts_with ~prefix:"Fail(eta-http error=Continuation_flood" msg
  || String.starts_with ~prefix:"Fail(eta-http error=Settings_count_exceeded" msg
  || String.starts_with ~prefix:"Fail(eta-http error=Ping_count_exceeded" msg

let assess name outcome expected =
  match outcome, expected with
  | Ok detail, Expect_response -> print_probe name PASS (Some detail)
  | Ok detail, (Expect_error | Expect_timeout) ->
      print_probe name FAIL (Some ("unexpected response: " ^ detail))
  | Eta_error msg, Expect_error when is_protocol_error msg ->
      print_probe name PASS (Some ("typed protocol error"))
  | Eta_error msg, Expect_timeout when is_timeout_error msg ->
      print_probe name PASS (Some "timed out cleanly")
  | Eta_error msg, (Expect_response | Expect_timeout) when is_protocol_error msg ->
      print_probe name FAIL (Some ("unexpected protocol error: " ^ msg))
  | Eta_error msg, (Expect_response | Expect_error) when is_timeout_error msg ->
      print_probe name FAIL (Some ("unexpected timeout: " ^ msg))
  | Eta_error msg, _ -> print_probe name FAIL (Some ("unexpected eta error: " ^ msg))
  | Hang detail, _ -> print_probe name HANG (Some detail)
  | Crash detail, _ -> print_probe name CRASH (Some detail)

let timeout_error ~url ~deadline_sec =
  let timeout_ms = max 1 (int_of_float (deadline_sec *. 1000.0)) in
  Eta_http.Error.make ~method_:"GET" ~uri:url
    (Total_request_timeout { timeout_ms = Some timeout_ms })

(* ---------------------------------------------------------------------------
   Raw flow helpers
   --------------------------------------------------------------------------- *)

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> invalid_arg "expected TCP listener"

let read_exact flow buf len =
  let rec loop off =
    if off >= len then ()
    else
      let n = Eio.Flow.single_read flow (Cstruct.sub buf off (len - off)) in
      if n = 0 then raise End_of_file else loop (off + n)
  in
  loop 0

let read_frame_header flow =
  let buf = Cstruct.create 9 in
  read_exact flow buf 9;
  let len =
    (Cstruct.get_uint8 buf 0 lsl 16)
    lor (Cstruct.get_uint8 buf 1 lsl 8)
    lor Cstruct.get_uint8 buf 2
  in
  let ty = Cstruct.get_uint8 buf 3 in
  let flags = Cstruct.get_uint8 buf 4 in
  let stream_id =
    ((Cstruct.get_uint8 buf 5 land 0x7F) lsl 24)
    lor (Cstruct.get_uint8 buf 6 lsl 16)
    lor (Cstruct.get_uint8 buf 7 lsl 8)
    lor Cstruct.get_uint8 buf 8
  in
  (len, ty, flags, stream_id)

let skip_frame_payload flow len =
  if len > 0 then (
    let buf = Cstruct.create len in
    let n = Eio.Flow.single_read flow buf in
    if n < len then raise End_of_file)

let write_string flow s = Eio.Flow.copy_string s flow

(* ---------------------------------------------------------------------------
   Malicious server lifecycle
   --------------------------------------------------------------------------- *)

let server_handshake flow =
  let buf = Cstruct.create 24 in
  read_exact flow buf 24;
  (* Client SETTINGS *)
  let len, ty, _flags, _sid = read_frame_header flow in
  if ty <> 0x04 then failwith "expected client SETTINGS frame";
  skip_frame_payload flow len;
  (* Server SETTINGS *)
  write_string flow (Malicious_h2.settings_frame [])

let read_client_headers flow =
  let rec loop () =
    let len, ty, _flags, sid = read_frame_header flow in
    if ty = 0x01 then sid
    else (
      skip_frame_payload flow len;
      loop ())
  in
  loop ()

let read_all_client_frames flow =
  let rec loop () =
    match read_frame_header flow with
    | len, _ty, _flags, _sid ->
        skip_frame_payload flow len;
        loop ()
    | exception End_of_file -> ()
  in
  loop ()

(* ---------------------------------------------------------------------------
   Client driver
   --------------------------------------------------------------------------- *)

let run_client_probe ~env ~name ~deadline_sec ~expected ~server_logic =
  let start = Unix.gettimeofday () in
  let outcome =
    try
      Eio.Switch.run @@ fun sw ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.clock env in
      let socket =
        Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
      in
      let port = tcp_port (Eio.Net.listening_addr socket) in
      let server_done, resolve_server_done = Eio.Promise.create () in
      Eio.Fiber.fork_daemon ~sw (fun () ->
          Eio.Switch.run @@ fun conn_sw ->
          let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
          Fun.protect
            ~finally:(fun () ->
                (try Eio.Flow.shutdown flow `All with _ -> ());
                ignore (Eio.Promise.try_resolve resolve_server_done ()))
            (fun () ->
               try server_logic ~clock flow
               with _ -> ());
          `Stop_daemon);
      let flow =
        Eio.Net.connect ~sw net
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
      in
      Fun.protect
        ~finally:(fun () ->
          try Eio.Flow.shutdown flow `All with _ -> ())
        (fun () ->
          try
            Eio.Time.with_timeout_exn clock deadline_sec (fun () ->
                let conn =
                  Eta_http_eio.H2.Connection.create ~sw ~now_ms:(fun () -> 0L)
                    ~flow:(flow :> Eta_http_eio.H2.Connection.flow)
                    ()
                in
                let uri = Printf.sprintf "http://127.0.0.1:%d/" port in
                let url = Eta_http.Core.Url.of_string uri in
                let request = Eta_http.Request.make "GET" uri in
                let rt = Eta_eio.Runtime.create ~sw ~clock () in
                (* The Eta-level timeout is slightly shorter than the Eio safety
                   deadline so that a correctly-handled timeout produces a typed
                   error rather than being recorded as a hang. *)
                let eta_timeout_sec = max 0.5 (deadline_sec -. 0.5) in
                let eta_timeout_ms =
                  max 1 (int_of_float (eta_timeout_sec *. 1000.0))
                in
                let effect =
                  Eta_http_eio.Client.request_h2_on_connection conn request url
                  |> Eta.Effect.catch (fun error -> Eta.Effect.fail error)
                  |> Eta.Effect.bind (fun (response : Eta_http.Response.t) ->
                         Eta_http.Body.Stream.read_all response.body
                         |> Eta.Effect.map (fun _ -> `Ok))
                in
                let timed =
                  Eta.Effect.timeout_as (Eta.Duration.ms eta_timeout_ms)
                    ~on_timeout:(timeout_error ~url:uri ~deadline_sec:eta_timeout_sec)
                    effect
                in
                match Eta.Runtime.run rt timed with
                | Eta.Exit.Ok `Ok -> Ok "response consumed"
                | Eta.Exit.Error cause ->
                    let msg =
                      Format.asprintf "%a" (Eta.Cause.pp Eta_http.Error.pp) cause
                    in
                    Eta_error msg
                | exception exn -> Crash (Printexc.to_string exn))
          with
          | Eio.Time.Timeout -> Hang "probe safety deadline exceeded"
          | exn -> Crash (Printexc.to_string exn))
    with exn -> Crash (Printexc.to_string exn)
  in
  let duration_ms = (Unix.gettimeofday () -. start) *. 1000.0 in
  assess name outcome expected;
  (name, outcome, duration_ms)

(* ---------------------------------------------------------------------------
   Probe server behaviours
   --------------------------------------------------------------------------- *)

(** 1. Server sends HEADERS without END_HEADERS and keeps the connection open.
    The client must not hang waiting for a response. *)
let serve_headers_without_end_headers ~clock flow =
  server_handshake flow;
  let sid = read_client_headers flow in
  write_string flow
    (Malicious_h2.headers_frame ~end_headers:false ~stream_id:sid
       Malicious_h2.hpack_indexed_status_200);
  (* Keep connection open long past the client deadline. *)
  Eio.Time.sleep clock 30.0

(** 2. Server sends an unending CONTINUATION chain. Tests header-list size
    limits and timeout handling. *)
let serve_continuation_never_ends ~clock flow =
  server_handshake flow;
  let sid = read_client_headers flow in
  write_string flow
    (Malicious_h2.headers_frame ~end_headers:false ~stream_id:sid
       Malicious_h2.hpack_indexed_status_200);
  for _i = 1 to 100_000 do
    write_string flow
      (Malicious_h2.continuation_frame ~end_headers:false ~stream_id:sid
         (Malicious_h2.hpack_literal ~name:"x-continuation" ~value:"a"))
  done;
  Eio.Time.sleep clock 30.0

(** 3. Server sends DATA before HEADERS on the response stream. *)
let serve_data_before_headers ~clock:_ flow =
  server_handshake flow;
  let sid = read_client_headers flow in
  write_string flow (Malicious_h2.data_frame ~end_stream:false ~stream_id:sid "x")

(** 4. Server sends RST_STREAM before any response HEADERS. *)
let serve_rst_stream_before_headers ~clock:_ flow =
  server_handshake flow;
  let sid = read_client_headers flow in
  write_string flow (Malicious_h2.rst_stream_frame ~stream_id:sid 1)

(** 5. Server sends GOAWAY immediately after the handshake. *)
let serve_goaway_immediately ~clock:_ flow =
  server_handshake flow;
  write_string flow (Malicious_h2.goaway_frame ~last_stream_id:0 ~error_code:0 ())

(** 6. Server starts a response with HEADERS and then sends GOAWAY. *)
let serve_goaway_after_headers ~clock:_ flow =
  server_handshake flow;
  let sid = read_client_headers flow in
  write_string flow
    (Malicious_h2.headers_frame ~end_headers:true ~stream_id:sid
       Malicious_h2.hpack_indexed_status_200);
  write_string flow (Malicious_h2.goaway_frame ~last_stream_id:sid ~error_code:0 ())

(** 7. Server sends a PUSH_PROMISE frame (server-initiated promise). The client
    does not enable push and should reject or ignore it. *)
let serve_push_promise ~clock:_ flow =
  server_handshake flow;
  let sid = read_client_headers flow in
  let promised_stream_id = sid + 2 in
  let hpack_block =
    String.concat ""
      [
        Malicious_h2.hpack_literal ~name:":method" ~value:"GET";
        Malicious_h2.hpack_literal ~name:":path" ~value:"/push";
        Malicious_h2.hpack_literal ~name:":scheme" ~value:"http";
        Malicious_h2.hpack_literal ~name:":authority" ~value:"example.test";
      ]
  in
  let payload =
    let buf = Bytes.create 4 in
    Bytes.set_int32_be buf 0
      (Int32.logand (Int32.of_int promised_stream_id) 0x7FFFFFFFl);
    Bytes.to_string buf ^ hpack_block
  in
  write_string flow (Malicious_h2.frame ~ty:0x05 ~flags:0x04 ~stream_id:sid payload)

(** 8. Server sends a WINDOW_UPDATE that overflows the flow-control window. *)
let serve_window_update_overflow ~clock:_ flow =
  server_handshake flow;
  let sid = read_client_headers flow in
  write_string flow (Malicious_h2.window_update_frame ~stream_id:sid 0x7FFFFFFF);
  write_string flow (Malicious_h2.window_update_frame ~stream_id:0 0x7FFFFFFF)

(** 9. Server sends HEADERS with END_STREAM and then more DATA. *)
let serve_data_after_end_stream ~clock:_ flow =
  server_handshake flow;
  let sid = read_client_headers flow in
  write_string flow
    (Malicious_h2.frame ~ty:0x01 ~flags:0x05 ~stream_id:sid
       Malicious_h2.hpack_indexed_status_200);
  write_string flow (Malicious_h2.data_frame ~end_stream:false ~stream_id:sid "x");
  write_string flow (Malicious_h2.data_frame ~end_stream:true ~stream_id:sid "y")

(** 10. Server waits a long time before sending response HEADERS. *)
let serve_slow_headers ~clock flow =
  server_handshake flow;
  ignore (read_client_headers flow : int);
  Eio.Time.sleep clock 30.0;
  write_string flow
    (Malicious_h2.headers_frame ~end_headers:true ~stream_id:1
       Malicious_h2.hpack_indexed_status_200)

(** 11. Server sends HEADERS then dribbles DATA very slowly. *)
let serve_slow_body ~clock flow =
  server_handshake flow;
  let sid = read_client_headers flow in
  write_string flow
    (Malicious_h2.headers_frame ~end_headers:true ~stream_id:sid
       Malicious_h2.hpack_indexed_status_200);
  for _i = 1 to 100 do
    Eio.Time.sleep clock 1.0;
    write_string flow (Malicious_h2.data_frame ~end_stream:false ~stream_id:sid "x")
  done

(** 12. Server floods SETTINGS frames. The client must ACK each one and not hang. *)
let serve_settings_flood ~clock flow =
  server_handshake flow;
  for _i = 1 to 200 do
    write_string flow (Malicious_h2.settings_frame [ (0x3, 100); (0x4, 65535) ])
  done;
  Eio.Time.sleep clock 30.0

(** 13. Server floods PING frames. The client must ACK each one. *)
let serve_ping_flood ~clock flow =
  server_handshake flow;
  for _i = 1 to 200 do
    write_string flow (Malicious_h2.ping_frame ~ack:false "ping!!!!")
  done;
  Eio.Time.sleep clock 30.0

(** 14. Server sends HEADERS on stream 0 (invalid). *)
let serve_headers_on_stream_zero ~clock:_ flow =
  server_handshake flow;
  write_string flow
    (Malicious_h2.headers_frame ~end_headers:true ~stream_id:0
       Malicious_h2.hpack_indexed_status_200)

(** 15. Server sends PRIORITY after HEADERS; PRIORITY should be ignored. *)
let serve_priority_after_headers ~clock:_ flow =
  server_handshake flow;
  let sid = read_client_headers flow in
  write_string flow
    (Malicious_h2.headers_frame ~end_headers:true ~stream_id:sid
       Malicious_h2.hpack_indexed_status_200);
  write_string flow
    (Malicious_h2.frame ~ty:0x02 ~flags:0x00 ~stream_id:sid
       "\x00\x00\x00\x00\x10");
  write_string flow (Malicious_h2.data_frame ~end_stream:true ~stream_id:sid "ok")

(** 16. Server sends an unknown frame type; should be ignored. *)
let serve_unknown_frame_type ~clock:_ flow =
  server_handshake flow;
  let sid = read_client_headers flow in
  write_string flow (Malicious_h2.frame ~ty:0xFF ~flags:0x00 ~stream_id:0 "hello");
  write_string flow
    (Malicious_h2.headers_frame ~end_headers:true ~stream_id:sid
       Malicious_h2.hpack_indexed_status_200);
  write_string flow (Malicious_h2.data_frame ~end_stream:true ~stream_id:sid "ok")

(** 17. Server sends RST_STREAM for a stream the client never opened. *)
let serve_rst_stream_on_idle ~clock flow =
  server_handshake flow;
  write_string flow (Malicious_h2.rst_stream_frame ~stream_id:1 8);
  Eio.Time.sleep clock 30.0

(** 18. Server GOAWAY with a last_stream_id larger than any opened stream.
    The server drains client frames so the client cannot blame a write stall. *)
let serve_goaway_high_last_stream_id ~clock flow =
  server_handshake flow;
  write_string flow
    (Malicious_h2.goaway_frame ~last_stream_id:0x7FFFFFFF ~error_code:0 ());
  (* Drain whatever the client sends so it has every chance to process GOAWAY
     and fail the request. *)
  let rec drain () =
    match read_frame_header flow with
    | len, _ty, _flags, _sid ->
        skip_frame_payload flow len;
        drain ()
    | exception End_of_file -> ()
  in
  drain ()

(** 19. Server sends HEADERS followed immediately by RST_STREAM (response
    aborted). *)
let serve_rst_stream_after_headers ~clock:_ flow =
  server_handshake flow;
  let sid = read_client_headers flow in
  write_string flow
    (Malicious_h2.headers_frame ~end_headers:true ~stream_id:sid
       Malicious_h2.hpack_indexed_status_200);
  write_string flow (Malicious_h2.rst_stream_frame ~stream_id:sid 8)

(** 20. Server sends valid response (sanity check). *)
let serve_valid_response ~clock:_ flow =
  server_handshake flow;
  let sid = read_client_headers flow in
  write_string flow
    (Malicious_h2.headers_frame ~end_headers:true ~stream_id:sid
       Malicious_h2.hpack_indexed_status_200);
  write_string flow (Malicious_h2.data_frame ~end_stream:true ~stream_id:sid "ok")

(** 21. HEADERS without END_HEADERS followed by a CONTINUATION on a different
    stream. *)
let serve_continuation_wrong_stream ~clock:_ flow =
  server_handshake flow;
  let sid = read_client_headers flow in
  write_string flow
    (Malicious_h2.headers_frame ~end_headers:false ~stream_id:sid
       Malicious_h2.hpack_indexed_status_200);
  write_string flow
    (Malicious_h2.continuation_frame ~end_headers:true ~stream_id:(sid + 2)
       (Malicious_h2.hpack_literal ~name:"x-end" ~value:"done"))

(** 22. Server SETTINGS includes ENABLE_PUSH=1, which a client must reject. *)
let serve_settings_invalid_enable_push ~clock:_ flow =
  server_handshake flow;
  write_string flow (Malicious_h2.settings_frame [ (0x2, 1) ])

(** 23. Server response HEADERS block is missing the mandatory :status field. *)
let serve_headers_missing_status ~clock:_ flow =
  server_handshake flow;
  let sid = read_client_headers flow in
  write_string flow
    (Malicious_h2.headers_frame ~end_headers:true ~stream_id:sid
       (Malicious_h2.hpack_literal ~name:"content-type" ~value:"text/plain"))

(* ---------------------------------------------------------------------------
   Probe definitions
   --------------------------------------------------------------------------- *)

let probe_headers_without_end_headers ~env =
  run_client_probe ~env ~name:"h2_client_malicious.headers_without_end_headers"
    ~deadline_sec:3.0 ~expected:Expect_timeout
    ~server_logic:serve_headers_without_end_headers

let probe_continuation_never_ends ~env =
  run_client_probe ~env ~name:"h2_client_malicious.continuation_never_ends"
    ~deadline_sec:3.0 ~expected:Expect_error
    ~server_logic:serve_continuation_never_ends

let probe_data_before_headers ~env =
  run_client_probe ~env ~name:"h2_client_malicious.data_before_headers"
    ~deadline_sec:3.0 ~expected:Expect_error
    ~server_logic:serve_data_before_headers

let probe_rst_stream_before_headers ~env =
  run_client_probe ~env ~name:"h2_client_malicious.rst_stream_before_headers"
    ~deadline_sec:3.0 ~expected:Expect_error
    ~server_logic:serve_rst_stream_before_headers

let probe_goaway_immediately ~env =
  run_client_probe ~env ~name:"h2_client_malicious.goaway_immediately"
    ~deadline_sec:3.0 ~expected:Expect_error
    ~server_logic:serve_goaway_immediately

let probe_goaway_after_headers ~env =
  run_client_probe ~env ~name:"h2_client_malicious.goaway_after_headers"
    ~deadline_sec:3.0 ~expected:Expect_error
    ~server_logic:serve_goaway_after_headers

let probe_push_promise ~env =
  run_client_probe ~env ~name:"h2_client_malicious.push_promise"
    ~deadline_sec:3.0 ~expected:Expect_error
    ~server_logic:serve_push_promise

let probe_window_update_overflow ~env =
  run_client_probe ~env ~name:"h2_client_malicious.window_update_overflow"
    ~deadline_sec:3.0 ~expected:Expect_error
    ~server_logic:serve_window_update_overflow

let probe_data_after_end_stream ~env =
  run_client_probe ~env ~name:"h2_client_malicious.data_after_end_stream"
    ~deadline_sec:3.0 ~expected:Expect_response
    ~server_logic:serve_data_after_end_stream

let probe_slow_headers ~env =
  run_client_probe ~env ~name:"h2_client_malicious.slow_headers"
    ~deadline_sec:3.0 ~expected:Expect_timeout
    ~server_logic:serve_slow_headers

let probe_slow_body ~env =
  run_client_probe ~env ~name:"h2_client_malicious.slow_body"
    ~deadline_sec:3.0 ~expected:Expect_timeout
    ~server_logic:serve_slow_body

let probe_settings_flood ~env =
  run_client_probe ~env ~name:"h2_client_malicious.settings_flood"
    ~deadline_sec:3.0 ~expected:Expect_error
    ~server_logic:serve_settings_flood

let probe_ping_flood ~env =
  run_client_probe ~env ~name:"h2_client_malicious.ping_flood"
    ~deadline_sec:3.0 ~expected:Expect_error
    ~server_logic:serve_ping_flood

let probe_headers_on_stream_zero ~env =
  run_client_probe ~env ~name:"h2_client_malicious.headers_on_stream_zero"
    ~deadline_sec:3.0 ~expected:Expect_error
    ~server_logic:serve_headers_on_stream_zero

let probe_priority_after_headers ~env =
  run_client_probe ~env ~name:"h2_client_malicious.priority_after_headers"
    ~deadline_sec:3.0 ~expected:Expect_response
    ~server_logic:serve_priority_after_headers

let probe_unknown_frame_type ~env =
  run_client_probe ~env ~name:"h2_client_malicious.unknown_frame_type"
    ~deadline_sec:3.0 ~expected:Expect_response
    ~server_logic:serve_unknown_frame_type

let probe_rst_stream_on_idle ~env =
  run_client_probe ~env ~name:"h2_client_malicious.rst_stream_on_idle"
    ~deadline_sec:3.0 ~expected:Expect_error
    ~server_logic:serve_rst_stream_on_idle

let probe_goaway_high_last_stream_id ~env =
  run_client_probe ~env ~name:"h2_client_malicious.goaway_high_last_stream_id"
    ~deadline_sec:3.0 ~expected:Expect_timeout
    ~server_logic:serve_goaway_high_last_stream_id

let probe_rst_stream_after_headers ~env =
  run_client_probe ~env ~name:"h2_client_malicious.rst_stream_after_headers"
    ~deadline_sec:3.0 ~expected:Expect_error
    ~server_logic:serve_rst_stream_after_headers

let probe_continuation_wrong_stream ~env =
  run_client_probe ~env ~name:"h2_client_malicious.continuation_wrong_stream"
    ~deadline_sec:3.0 ~expected:Expect_error
    ~server_logic:serve_continuation_wrong_stream

let probe_settings_invalid_enable_push ~env =
  run_client_probe ~env ~name:"h2_client_malicious.settings_invalid_enable_push"
    ~deadline_sec:3.0 ~expected:Expect_error
    ~server_logic:serve_settings_invalid_enable_push

let probe_headers_missing_status ~env =
  run_client_probe ~env ~name:"h2_client_malicious.headers_missing_status"
    ~deadline_sec:3.0 ~expected:Expect_error
    ~server_logic:serve_headers_missing_status

let probe_valid_response ~env =
  run_client_probe ~env ~name:"h2_client_malicious.valid_response"
    ~deadline_sec:3.0 ~expected:Expect_response
    ~server_logic:serve_valid_response

(* ---------------------------------------------------------------------------
   Main
   --------------------------------------------------------------------------- *)

let () =
  Eio_main.run @@ fun env ->
  let probes =
    [
      probe_valid_response;
      probe_headers_without_end_headers;
      probe_continuation_never_ends;
      probe_data_before_headers;
      probe_rst_stream_before_headers;
      probe_goaway_immediately;
      probe_goaway_after_headers;
      probe_push_promise;
      probe_window_update_overflow;
      probe_data_after_end_stream;
      probe_slow_headers;
      probe_slow_body;
      probe_settings_flood;
      probe_ping_flood;
      probe_headers_on_stream_zero;
      probe_priority_after_headers;
      probe_unknown_frame_type;
      probe_rst_stream_on_idle;
      probe_goaway_high_last_stream_id;
      probe_rst_stream_after_headers;
      probe_continuation_wrong_stream;
      probe_settings_invalid_enable_push;
      probe_headers_missing_status;
    ]
  in
  List.iter (fun f -> ignore (f ~env : _)) probes;
  Printf.printf "h2_client_malicious done\n%!"
