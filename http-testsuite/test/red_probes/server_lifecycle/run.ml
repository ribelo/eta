(** server_lifecycle: server lifecycle and shutdown red probes.

    These probes exercise Eta HTTP server shutdown paths with active work in
    flight. A hang past the deadline is recorded as a finding, not a test
    failure. The runner always exits 0. *)

open Eio.Std
open Eta_http_testsuite

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

let h1_config ?handler_timeout ?request_body_timeout ?response_write_timeout () =
  let server =
    {
      Eta_http.Server.Config.default with
      enable_otel = false;
      timeouts =
        {
          Eta_http.Server.Config.default.timeouts with
          handler_timeout;
          request_body_timeout;
          response_write_timeout;
        };
    }
  in
  {
    Eta_http_eio.Server.Config.default with
    backlog = 8;
    max_connections = 32;
    server;
  }

let h2_config ?handler_timeout ?request_body_timeout ?response_write_timeout () =
  let server =
    {
      Eta_http.Server.Config.default with
      enable_otel = false;
      timeouts =
        {
          Eta_http.Server.Config.default.timeouts with
          handler_timeout;
          request_body_timeout;
          response_write_timeout;
        };
    }
  in
  {
    (Adversarial.h2_adversarial_config ()) with
    max_connections = 32;
    server;
  }

let start_h1_server ~sw ~env ~(config : Eta_http_eio.Server.Config.t) handler =
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:config.backlog net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let server =
    Eta_http_eio.Server.start_h1_on_socket ~sw ~clock ~config ~socket handler
  in
  (server, port)

let connect_client ~sw env port =
  let net = Eio.Stdenv.net env in
  Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))

let send_string flow s = Eio.Flow.copy_string s flow

let string_contains needle haystack =
  let n = String.length needle in
  let h = String.length haystack in
  let rec loop i =
    if i + n > h then false
    else if String.starts_with ~prefix:needle (String.sub haystack i (h - i))
    then true
    else loop (i + 1)
  in
  loop 0

let drain_until_close ?(max_bytes = 64 * 1024) flow =
  let buf = Buffer.create 256 in
  let scratch = Cstruct.create 4096 in
  let rec loop total =
    if total >= max_bytes then `Data_limit (Buffer.contents buf)
    else
      match Eio.Flow.single_read flow scratch with
      | 0 -> `Closed (Buffer.contents buf)
      | n ->
          Buffer.add_string buf
            (Cstruct.to_string (Cstruct.sub scratch 0 n));
          loop (total + n)
      | exception End_of_file -> `Closed (Buffer.contents buf)
  in
  loop 0

let wait_for_zero_active ~clock ~server ~deadline_sec =
  try
    Eio.Time.with_timeout_exn clock deadline_sec (fun () ->
        while (Eta_http_eio.Server.stats server).active_connections > 0 do
          Eio.Time.sleep clock 0.01
        done;
        true)
  with Eio.Time.Timeout -> false

let probe_wrap ~name ~deadline_sec f env =
  let start = Unix.gettimeofday () in
  let status, detail =
    try
      let clock = Eio.Stdenv.clock env in
      Eio.Time.with_timeout_exn clock deadline_sec (fun () ->
          Eio.Switch.run @@ fun sw -> f ~sw ~clock ())
    with
    | Eio.Time.Timeout -> (Hang, "deadline exceeded")
    | exn -> (Crash, Printexc.to_string exn)
  in
  let duration_ms = (Unix.gettimeofday () -. start) *. 1000.0 in
  Printf.printf "probe %s %s %s (%.0fms)\n%!" name (status_to_string status)
    detail duration_ms;
  (name, status, detail)

(* ---------------------------------------------------------------------------
   H1 probes
   --------------------------------------------------------------------------- *)

(** Handler that sleeps for a fixed duration before responding. *)
let sleeping_handler clock duration _request =
  Eio.Time.sleep clock duration;
  Eta.Effect.pure (Eta_http.Server.Response.text "ok\n")

(** Handler that reads the entire request body, then responds. *)
let echo_handler request =
  Eta_http.Server.Body.read_all request.Eta_http.Server.Request.body
  |> Eta.Effect.map (fun body ->
         Eta_http.Server.Response.text (Bytes.to_string body))

(** Handler that produces an infinite chunked response. *)
let streaming_handler clock _request =
  let remaining = ref 100 in
  let read () =
    if !remaining <= 0 then Eta.Effect.pure None
    else (
      Eio.Time.sleep clock 0.05;
      remaining := !remaining - 1;
      Eta.Effect.pure (Some (Bytes.make 256 'x')))
  in
  Eta.Effect.pure
    (Eta_http.Server.Response.make ~status:200
       ~body:(Eta_http.Server.Response.Body.stream read)
       ())

(** 1. Immediate shutdown while a handler is sleeping.
    The server should stop accepting and close the connection promptly,
    without waiting for the handler to finish sleeping. *)
let probe_h1_immediate_shutdown_sleeping_handler env =
  probe_wrap ~name:"h1_immediate_shutdown_sleeping_handler" ~deadline_sec:2.0
    (fun ~sw ~clock () ->
      let handler = sleeping_handler clock 5.0 in
      let config = h1_config ~handler_timeout:(Eta.Duration.seconds 30) () in
      let server, port = start_h1_server ~sw ~env ~config handler in
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Switch.run @@ fun client_sw ->
          let flow = connect_client ~sw:client_sw env port in
          Fun.protect
            ~finally:(fun () ->
              try Eio.Flow.shutdown flow `All with _ -> ())
            (fun () ->
              send_string flow "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n";
              ignore (drain_until_close flow)));
      Eio.Time.sleep clock 0.1;
      Eta_http_eio.Server.shutdown server Immediate;
      if wait_for_zero_active ~clock ~server ~deadline_sec:1.5 then
        (Pass, "active connections dropped after immediate shutdown")
      else (Fail, "active connections still present after immediate shutdown"))
    env

(** 2. Graceful shutdown with an active upload.
    The client sends headers for a large body and stalls. The graceful timeout
    should close the connection even though the handler is blocked reading. *)
let probe_h1_graceful_shutdown_active_upload env =
  probe_wrap ~name:"h1_graceful_shutdown_active_upload" ~deadline_sec:3.0
    (fun ~sw ~clock () ->
      let config =
        h1_config ~request_body_timeout:(Eta.Duration.seconds 30) ()
      in
      let server, port = start_h1_server ~sw ~env ~config echo_handler in
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Switch.run @@ fun client_sw ->
          let flow = connect_client ~sw:client_sw env port in
          Fun.protect
            ~finally:(fun () ->
              try Eio.Flow.shutdown flow `All with _ -> ())
            (fun () ->
              send_string flow
                ("POST / HTTP/1.1\r\nHost: example.test\r\n"
               ^ "Content-Length: 1000000\r\n\r\nhello");
              ignore (drain_until_close flow)));
      Eio.Time.sleep clock 0.1;
      Eta_http_eio.Server.shutdown server
        (Eta_http_eio.Server.Graceful (Eta.Duration.ms 200));
      if wait_for_zero_active ~clock ~server ~deadline_sec:2.0 then
        (Pass, "active connections dropped after graceful shutdown")
      else (Fail, "active connections still present after graceful shutdown"))
    env

(** 3. Immediate shutdown mid-streaming-response.
    The handler streams forever; shutdown Immediate should close the response
    stream and the connection quickly. *)
let probe_h1_immediate_mid_streaming_response env =
  probe_wrap ~name:"h1_immediate_mid_streaming_response" ~deadline_sec:3.0
    (fun ~sw ~clock () ->
      let config = h1_config () in
      let server, port = start_h1_server ~sw ~env ~config (streaming_handler clock) in
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Switch.run @@ fun client_sw ->
          let flow = connect_client ~sw:client_sw env port in
          Fun.protect
            ~finally:(fun () ->
              try Eio.Flow.shutdown flow `All with _ -> ())
            (fun () ->
              send_string flow "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n";
              (* read headers then let the stream flow *)
              let scratch = Cstruct.create 1024 in
              let rec read_headers () =
                match Eio.Flow.single_read flow scratch with
                | 0 -> ()
                | n ->
                    let s = Cstruct.to_string (Cstruct.sub scratch 0 n) in
                    if String.contains s '\n' then ignore (drain_until_close flow)
                    else read_headers ()
                | exception End_of_file -> ()
              in
              read_headers ()));
      Eio.Time.sleep clock 0.2;
      Eta_http_eio.Server.shutdown server Immediate;
      if wait_for_zero_active ~clock ~server ~deadline_sec:2.0 then
        (Pass, "streaming response connection closed")
      else (Fail, "streaming response connection stayed open"))
    env

(** 4. Shutdown during request body read.
    The client sends a request body slowly. Immediate shutdown should close the
    connection without waiting for the body transfer to complete. *)
let probe_h1_shutdown_during_request_body_read env =
  probe_wrap ~name:"h1_shutdown_during_request_body_read" ~deadline_sec:3.0
    (fun ~sw ~clock () ->
      let config =
        h1_config ~request_body_timeout:(Eta.Duration.seconds 30) ()
      in
      let server, port = start_h1_server ~sw ~env ~config echo_handler in
      let body_sent = ref 0 in
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Switch.run @@ fun client_sw ->
          let flow = connect_client ~sw:client_sw env port in
          Fun.protect
            ~finally:(fun () ->
              try Eio.Flow.shutdown flow `All with _ -> ())
            (fun () ->
              send_string flow
                ("POST / HTTP/1.1\r\nHost: example.test\r\n"
               ^ "Content-Length: 1000000\r\n\r\n");
              (try
                 while !body_sent < 100 do
                   send_string flow "x";
                   body_sent := !body_sent + 1;
                   Eio.Time.sleep clock 0.05
                 done
               with _ -> ());
              ignore (drain_until_close flow)));
      Eio.Time.sleep clock 0.3;
      Eta_http_eio.Server.shutdown server Immediate;
      if wait_for_zero_active ~clock ~server ~deadline_sec:2.0 then
        (Pass, "connection closed during body read")
      else (Fail, "connection stayed open during body read"))
    env

(** 5. Many concurrent connections then immediate shutdown.
    Multiple slow handlers are running. Immediate shutdown should close all of
    them promptly. *)
let probe_h1_many_connections_then_shutdown env =
  probe_wrap ~name:"h1_many_connections_then_shutdown" ~deadline_sec:4.0
    (fun ~sw ~clock () ->
      let config = h1_config ~handler_timeout:(Eta.Duration.seconds 30) () in
      let server, port = start_h1_server ~sw ~env ~config (sleeping_handler clock 8.0) in
      let client_count = 8 in
      for _i = 1 to client_count do
        Eio.Fiber.fork ~sw (fun () ->
            Eio.Switch.run @@ fun client_sw ->
            let flow = connect_client ~sw:client_sw env port in
            Fun.protect
              ~finally:(fun () ->
                try Eio.Flow.shutdown flow `All with _ -> ())
              (fun () ->
                send_string flow "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n";
                ignore (drain_until_close flow)))
      done;
      Eio.Time.sleep clock 0.3;
      let before = (Eta_http_eio.Server.stats server).active_connections in
      Eta_http_eio.Server.shutdown server Immediate;
      if wait_for_zero_active ~clock ~server ~deadline_sec:3.0 then
        ( Pass,
          Printf.sprintf "all %d/%d connections closed" before client_count )
      else
        ( Fail,
          Printf.sprintf "%d connections still active"
            (Eta_http_eio.Server.stats server).active_connections ))
    env

(** 6. Repeated start/stop cycles.
    Start a server, make one request, stop it, and repeat. File descriptor
    count should remain bounded. *)
let probe_h1_repeated_start_stop env =
  probe_wrap ~name:"h1_repeated_start_stop" ~deadline_sec:15.0
    (fun ~sw ~clock () ->
      let config = h1_config () in
      let fd_before = Util.fd_count () in
      let ok = ref 0 in
      for cycle = 1 to 8 do
        Eio.Switch.run @@ fun cycle_sw ->
        let handler _request = Eta.Effect.pure (Eta_http.Server.Response.text "ok\n") in
        let server, port = start_h1_server ~sw:cycle_sw ~env ~config handler in
        Eio.Switch.run @@ fun client_sw ->
        let flow = connect_client ~sw:client_sw env port in
        Fun.protect
          ~finally:(fun () ->
            try Eio.Flow.shutdown flow `All with _ -> ())
          (fun () ->
            send_string flow
              "GET / HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n";
            match drain_until_close flow with
            | `Closed data when string_contains "200" data -> ok := !ok + 1
            | _ -> ());
        Eta_http_eio.Server.shutdown server Immediate
      done;
      Eio.Time.sleep clock 0.2;
      let fd_after = Util.fd_count () in
      if !ok = 8 && fd_after <= fd_before + 4 then
        (Pass, Printf.sprintf "8 cycles ok, fd %d -> %d" fd_before fd_after)
      else if !ok <> 8 then
        (Fail, Printf.sprintf "only %d/8 cycles succeeded" !ok)
      else
        ( Policy_gap,
          Printf.sprintf "fd leak: %d -> %d" fd_before fd_after ))
    env

(** 7. Listener close while connections are active.
    After shutdown Immediate, the listener should stop accepting new
    connections. We try to connect after shutdown and expect refusal/close. *)
let probe_h1_listener_close_while_active env =
  (* Keep the handler alive briefly after shutdown so we can observe whether
     the listener socket still accepts new TCP connections. The handler is
     intentionally short so the probe can still exit cleanly. *)
  probe_wrap ~name:"h1_listener_close_while_active" ~deadline_sec:2.5
    (fun ~sw ~clock () ->
      let config = h1_config ~handler_timeout:(Eta.Duration.seconds 30) () in
      let server, port = start_h1_server ~sw ~env ~config (sleeping_handler clock 1.0) in
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Switch.run @@ fun client_sw ->
          let flow = connect_client ~sw:client_sw env port in
          Fun.protect
            ~finally:(fun () ->
              try Eio.Flow.shutdown flow `All with _ -> ())
            (fun () ->
              send_string flow "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n";
              ignore (drain_until_close flow)));
      Eio.Time.sleep clock 0.2;
      Eta_http_eio.Server.shutdown server Immediate;
      Eio.Time.sleep clock 0.1;
      let post_shutdown_connect =
        try
          Eio.Time.with_timeout_exn clock 1.0 (fun () ->
              Eio.Switch.run @@ fun client_sw ->
              let flow = connect_client ~sw:client_sw env port in
              (try Eio.Flow.shutdown flow `All with _ -> ());
              `accepted)
        with
        | Eio.Time.Timeout -> `timeout
        | exn -> `error (Printexc.to_string exn)
      in
      match post_shutdown_connect with
      | `accepted ->
          ( Policy_gap,
            "new TCP connection accepted after shutdown Immediate" )
      | `timeout -> (Pass, "connect timed out after shutdown")
      | `error _ -> (Pass, "connect refused/closed after shutdown"))
    env

(* ---------------------------------------------------------------------------
   H2 probes
   --------------------------------------------------------------------------- *)

let h2_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

let h2_handshake flow =
  send_string flow h2_preface;
  send_string flow (Malicious_h2.settings_frame []);
  let buf = Cstruct.create 9 in
  let rec loop () =
    let n = Eio.Flow.single_read flow buf in
    if n = 0 then raise End_of_file;
    let len =
      (Cstruct.get_uint8 buf 0 lsl 16)
      lor (Cstruct.get_uint8 buf 1 lsl 8)
      lor Cstruct.get_uint8 buf 2
    in
    let ty = Cstruct.get_uint8 buf 3 in
    if ty = 0x04 then (
      (* Consume the SETTINGS payload and ACK it. *)
      let payload_buf = Cstruct.create len in
      let rec read_payload off =
        if off >= len then ()
        else
          let r = Eio.Flow.single_read flow (Cstruct.sub payload_buf off (len - off)) in
          if r = 0 then raise End_of_file;
          read_payload (off + r)
      in
      read_payload 0;
      send_string flow (Malicious_h2.settings_frame ~ack:true []))
    else if ty = 0x07 then (
      let payload_buf = Cstruct.create len in
      let rec read_payload off =
        if off >= len then ()
        else
          let r = Eio.Flow.single_read flow (Cstruct.sub payload_buf off (len - off)) in
          if r = 0 then raise End_of_file;
          read_payload (off + r)
      in
      read_payload 0)
    else loop ()
  in
  loop ()

let h2_request_headers = Adversarial.h2_request_headers

let start_h2_server ~sw ~env ~(config : Eta_http_eio.Server.Config.t) handler =
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:config.backlog net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let server =
    Eta_http_eio.Server.start_h2c_on_socket ~sw ~clock ~config ~socket handler
  in
  (server, port)

(** 8. H2 immediate shutdown while a handler is sleeping. *)
let probe_h2_immediate_shutdown_sleeping_handler env =
  probe_wrap ~name:"h2_immediate_shutdown_sleeping_handler" ~deadline_sec:3.0
    (fun ~sw ~clock () ->
      let config =
        h2_config ~handler_timeout:(Eta.Duration.seconds 30) ()
      in
      let server, port = start_h2_server ~sw ~env ~config (sleeping_handler clock 8.0) in
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Switch.run @@ fun client_sw ->
          let flow = connect_client ~sw:client_sw env port in
          Fun.protect
            ~finally:(fun () ->
              try Eio.Flow.shutdown flow `All with _ -> ())
            (fun () ->
              h2_handshake flow;
              send_string flow (h2_request_headers ~stream_id:1 ());
              ignore (drain_until_close flow)));
      Eio.Time.sleep clock 0.1;
      Eta_http_eio.Server.shutdown server Immediate;
      if wait_for_zero_active ~clock ~server ~deadline_sec:2.0 then
        (Pass, "h2 active connections dropped after immediate shutdown")
      else (Fail, "h2 active connections still present after immediate shutdown"))
    env

(** 9. H2 graceful shutdown with an active client stream.
    The client opens a POST stream but never ends it. Graceful shutdown should
    send GOAWAY and close within the timeout. *)
let probe_h2_graceful_shutdown_active_stream env =
  probe_wrap ~name:"h2_graceful_shutdown_active_stream" ~deadline_sec:3.0
    (fun ~sw ~clock () ->
      let config =
        h2_config ~request_body_timeout:(Eta.Duration.seconds 30) ()
      in
      let server, port = start_h2_server ~sw ~env ~config echo_handler in
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Switch.run @@ fun client_sw ->
          let flow = connect_client ~sw:client_sw env port in
          Fun.protect
            ~finally:(fun () ->
              try Eio.Flow.shutdown flow `All with _ -> ())
            (fun () ->
              h2_handshake flow;
              send_string flow
                (h2_request_headers ~method_:"POST" ~end_stream:false
                   ~stream_id:1 ());
              ignore (drain_until_close flow)));
      Eio.Time.sleep clock 0.1;
      Eta_http_eio.Server.shutdown server
        (Eta_http_eio.Server.Graceful (Eta.Duration.ms 200));
      if wait_for_zero_active ~clock ~server ~deadline_sec:2.0 then
        (Pass, "h2 graceful shutdown closed active stream")
      else (Fail, "h2 graceful shutdown left active stream open"))
    env

(** 10. H2 many concurrent streams then immediate shutdown. *)
let probe_h2_many_streams_then_shutdown env =
  probe_wrap ~name:"h2_many_streams_then_shutdown" ~deadline_sec:4.0
    (fun ~sw ~clock () ->
      let config =
        h2_config ~handler_timeout:(Eta.Duration.seconds 30) ()
      in
      let server, port = start_h2_server ~sw ~env ~config (sleeping_handler clock 8.0) in
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Switch.run @@ fun client_sw ->
          let flow = connect_client ~sw:client_sw env port in
          Fun.protect
            ~finally:(fun () ->
              try Eio.Flow.shutdown flow `All with _ -> ())
            (fun () ->
              h2_handshake flow;
              for i = 1 to 8 do
                let stream_id = (i * 2) - 1 in
                send_string flow (h2_request_headers ~stream_id ())
              done;
              ignore (drain_until_close flow)));
      Eio.Time.sleep clock 0.3;
      Eta_http_eio.Server.shutdown server Immediate;
      if wait_for_zero_active ~clock ~server ~deadline_sec:3.0 then
        (Pass, "h2 all streams closed after immediate shutdown")
      else
        ( Fail,
          Printf.sprintf "h2 %d streams still active"
            (Eta_http_eio.Server.stats server).active_connections ))
    env

(* ---------------------------------------------------------------------------
   Main
   --------------------------------------------------------------------------- *)

let () =
  Eio_main.run @@ fun env ->
  let probes =
    [
      probe_h1_immediate_shutdown_sleeping_handler env;
      probe_h1_graceful_shutdown_active_upload env;
      probe_h1_immediate_mid_streaming_response env;
      probe_h1_shutdown_during_request_body_read env;
      probe_h1_many_connections_then_shutdown env;
      probe_h1_repeated_start_stop env;
      probe_h1_listener_close_while_active env;
      probe_h2_immediate_shutdown_sleeping_handler env;
      probe_h2_graceful_shutdown_active_stream env;
      probe_h2_many_streams_then_shutdown env;
    ]
  in
  let findings = List.filter (fun (_, s, _) -> s <> Pass) probes in
  Printf.printf "server_lifecycle done (%d/%d non-PASS)\n%!"
    (List.length findings) (List.length probes)
