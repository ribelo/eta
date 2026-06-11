open Test_eta_http_support
open Eta_http_eio

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> Alcotest.fail "expected TCP listener"

let wait_for_server_stats clock server predicate =
  Eio.Time.with_timeout_exn clock 1.0 (fun () ->
      let rec loop () =
        let stats = Server.stats server in
        if predicate stats then stats
        else (
          Eio.Time.sleep clock 0.01;
          loop ())
      in
      loop ())

let test_server_stats_listener_snapshot () =
  let stats = Server_stats.Listener.create () in
  Server_stats.Listener.opened_connection stats;
  Server_stats.Listener.opened_connection stats;
  Server_stats.Listener.closed_connection stats;
  Server_stats.Listener.tls_handshake stats;
  Server_stats.Listener.tls_handshake_failure stats;
  Server_stats.Listener.alpn_h1 stats;
  Server_stats.Listener.alpn_h2 stats;
  Server_stats.Listener.alpn_rejected stats;
  Server_stats.Listener.listener_error stats;
  let snapshot : Server_stats.Listener.snapshot =
    Server_stats.Listener.snapshot stats ~active_connections:1
  in
  Alcotest.(check int) "active connections" 1 snapshot.active_connections;
  Alcotest.(check int) "opened connections" 2 snapshot.opened_connections;
  Alcotest.(check int) "closed connections" 1 snapshot.closed_connections;
  Alcotest.(check int) "tls handshakes" 1 snapshot.tls_handshakes;
  Alcotest.(check int)
    "tls handshake failures" 1 snapshot.tls_handshake_failures;
  Alcotest.(check int) "alpn h1" 1 snapshot.alpn_h1;
  Alcotest.(check int) "alpn h2" 1 snapshot.alpn_h2;
  Alcotest.(check int) "alpn rejected" 1 snapshot.alpn_rejected;
  Alcotest.(check int) "listener errors" 1 snapshot.listener_errors

let test_server_listener_error_callback_and_stats () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let seen_error = ref None in
  let runtime_factory ~sw:_ ~connection:_ () =
    failwith "listener setup boom"
  in
  let handler _request =
    Eta.Effect.pure (Eta_http.Server.Response.text "unexpected\n")
  in
  let server =
    Server.start_h1_on_socket ~sw ~clock ~runtime_factory
      ~on_error:(fun exn -> seen_error := Some (Printexc.to_string exn))
      ~socket handler
  in
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  (try Eio.Flow.close flow with _ -> ());
  let stats =
    wait_for_server_stats clock server (fun stats ->
        stats.listener_errors = 1)
  in
  Alcotest.(check int) "listener errors" 1 stats.listener_errors;
  (match !seen_error with
  | Some message ->
      Alcotest.(check bool) "callback error" true
        (contains message "listener setup boom")
  | None -> Alcotest.fail "expected listener error callback");
  Server.shutdown server Immediate

let test_server_stats_h1_snapshot () =
  let stats = Server_stats.H1.create () in
  Server_stats.H1.request_started stats;
  Server_stats.H1.add_request_bytes stats 11;
  Server_stats.H1.add_response_bytes stats 29;
  Server_stats.H1.protocol_error stats;
  Server_stats.H1.request_completed stats;
  let snapshot : Server_stats.H1.snapshot = Server_stats.H1.snapshot stats in
  Alcotest.(check int) "active requests" 0 snapshot.active_requests;
  Alcotest.(check int) "completed requests" 1 snapshot.completed_requests;
  Alcotest.(check int) "request bytes" 11 snapshot.request_bytes;
  Alcotest.(check int) "response bytes" 29 snapshot.response_bytes;
  Alcotest.(check int) "protocol errors" 1 snapshot.protocol_errors

let test_server_stats_h2_snapshot () =
  let stats = Server_stats.H2.create () in
  Server_stats.H2.stream_opened stats;
  Server_stats.H2.stream_opened stats;
  Server_stats.H2.stream_completed stats;
  Server_stats.H2.stream_reset stats;
  Server_stats.H2.add_reset_streams stats 2;
  Server_stats.H2.add_request_bytes stats 17;
  Server_stats.H2.add_response_bytes stats 31;
  Server_stats.H2.protocol_error stats;
  let snapshot : Server_stats.H2.snapshot =
    Server_stats.H2.snapshot stats ~active_streams:1
  in
  Alcotest.(check int) "active streams" 1 snapshot.active_streams;
  Alcotest.(check int) "opened streams" 2 snapshot.opened_streams;
  Alcotest.(check int) "completed streams" 1 snapshot.completed_streams;
  Alcotest.(check int) "reset streams" 3 snapshot.reset_streams;
  Alcotest.(check int) "request bytes" 17 snapshot.request_bytes;
  Alcotest.(check int) "response bytes" 31 snapshot.response_bytes;
  Alcotest.(check int) "protocol errors" 1 snapshot.protocol_errors
