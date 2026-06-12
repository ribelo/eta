open Test_eta_http_support

let check_invalid label message config =
  Alcotest.check_raises label (Invalid_argument message) (fun () ->
      Eta_http_eio.Server.Config.validate config)

let test_server_config_validation () =
  let config = Eta_http_eio.Server.Config.default in
  Eta_http_eio.Server.Config.validate config;
  check_invalid "max connections"
    "Eta_http_eio.Server.Config.max_connections must be > 0"
    { config with max_connections = 0 };
  check_invalid "backlog"
    "Eta_http_eio.Server.Config.backlog must be > 0"
    { config with backlog = 0 };
  check_invalid "read buffer"
    "Eta_http_eio.Server.Config.read_buffer_size must be > 0"
    { config with read_buffer_size = 0 };
  check_invalid "command queue"
    "Eta_http_eio.Server.Config.command_queue_capacity must be > 0"
    { config with command_queue_capacity = 0 };
  check_invalid "tls handshake"
    "Eta_http_eio.Server.Config.tls_handshake_timeout must be > 0"
    { config with tls_handshake_timeout = Eta.Duration.zero };
  let server =
    {
      config.server with
      limits = { config.server.limits with max_request_headers = 0 };
    }
  in
  check_invalid "backend-neutral server config"
    "Eta_http.Server.Config.max_request_headers must be > 0"
    { config with server };
  let h2_config =
    { config.h2_config with read_buffer_size = 1024 }
  in
  check_invalid "h2 frame size"
    "Eta_http_eio.Server.Config.h2_config.read_buffer_size must be between 16384 and 16777215"
    { config with h2_config };
  let h2_config =
    { config.h2_config with request_body_buffer_size = 0 }
  in
  check_invalid "h2 request body buffer"
    "Eta_http_eio.Server.Config.h2_config.request_body_buffer_size must be > 0"
    { config with h2_config };
  let h2_config =
    { config.h2_config with max_concurrent_streams = 0l }
  in
  check_invalid "h2 concurrent streams"
    "Eta_http_eio.Server.Config.h2_config.max_concurrent_streams must be > 0"
    { config with h2_config };
  let h2_config =
    { config.h2_config with initial_window_size = -1l }
  in
  check_invalid "h2 initial window"
    "Eta_http_eio.Server.Config.h2_config.initial_window_size must be >= 0"
    { config with h2_config };
  let h2_security_config =
    {
      Eta_http.H2.Security.default_config with
      max_ping_per_connection = 0;
    }
  in
  check_invalid "h2 security"
    "Eta_http_eio.Server.Config.h2_security_config.max_ping_per_connection must be > 0"
    { config with h2_security_config = Some h2_security_config }

let test_start_h1_validates_config_before_fork () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let config =
    { Eta_http_eio.Server.Config.default with max_connections = 0 }
  in
  let handler _request =
    Eta.Effect.pure (Eta_http.Server.Response.text "unexpected\n")
  in
  Alcotest.check_raises "start validates"
    (Invalid_argument
       "Eta_http_eio.Server.Config.max_connections must be > 0")
    (fun () ->
      ignore
        (Eta_http_eio.Server.start_h1_on_socket ~sw ~clock ~config ~socket
           handler
          : Eta_http_eio.Server.t))


let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> Alcotest.fail "expected TCP listener"

let test_server_start_desired_port () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let desired_port =
    Eio.Switch.run @@ fun probe_sw ->
    let probe =
      Eio.Net.listen ~sw:probe_sw ~reuse_addr:true ~backlog:1 net
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
    in
    tcp_port (Eio.Net.listening_addr probe)
  in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, desired_port))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  Alcotest.(check int) "desired port bound" desired_port port;
  let handler _request =
    Eta.Effect.pure (Eta_http.Server.Response.text "ok")
  in
  let server =
    Eta_http_eio.Server.start_h1_on_socket ~sw ~clock ~socket handler
  in
  Eta_http_eio.Server.shutdown server Immediate;
  Alcotest.(check unit) "shutdown completes" () ()

let test_server_start_available_port () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  Alcotest.(check bool) "available port assigned" true (port <> 0);
  let handler _request =
    Eta.Effect.pure (Eta_http.Server.Response.text "ok")
  in
  let server =
    Eta_http_eio.Server.start_h1_on_socket ~sw ~clock ~socket handler
  in
  Eta_http_eio.Server.shutdown server Immediate;
  Alcotest.(check unit) "shutdown completes" () ()

let test_server_shutdown_before_connections () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let handler _request =
    Eta.Effect.pure (Eta_http.Server.Response.text "ok")
  in
  let server =
    Eta_http_eio.Server.start_h1_on_socket ~sw ~clock ~socket handler
  in
  Eta_http_eio.Server.shutdown server Immediate;
  (* zio-http allows providing a Server layer without starting it; Eta's
     equivalent is calling shutdown immediately after start_h1_on_socket,
     before any connection is accepted. *)
  Alcotest.(check unit) "shutdown before connections completes" () ()
