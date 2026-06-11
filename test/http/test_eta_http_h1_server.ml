open Test_eta_http_support

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> Alcotest.fail "expected TCP listener"

let read_all_response flow =
  let buffer = Buffer.create 128 in
  let scratch = Cstruct.create 1024 in
  let rec loop () =
    match Eio.Flow.single_read flow scratch with
    | 0 -> Buffer.contents buffer
    | len ->
        Buffer.add_string buffer (Cstruct.to_string (Cstruct.sub scratch 0 len));
        loop ()
    | exception End_of_file -> Buffer.contents buffer
  in
  loop ()

let with_h1_connection handler client_action =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let closed_stats, resolve_closed_stats = Eio.Promise.create () in
  let runtime_factory ~sw ~connection:_ () =
    Eta_eio.Runtime.create ~sw ~clock ()
  in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Switch.run @@ fun conn_sw ->
      let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
      let connection : Eta_http_eio.Server.Connection_info.t =
        {
          id = "h1-test-connection";
          peer = { address = Some "127.0.0.1"; port = Some port };
          protocol = Eta_http.Server.Error.H1;
          tls = false;
          alpn_protocol = None;
        }
      in
      Eta_http_eio.H1.Server_connection.run ~sw:conn_sw ~clock
        ~flow:(flow :> Eta_http_eio.H1.Server_connection.flow)
        ~connection ~config:Eta_http_eio.Server.Config.default
        ~runtime_factory
        ~on_close:(fun stats ->
          ignore (Eio.Promise.try_resolve resolve_closed_stats stats))
        handler);
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  Fun.protect
    ~finally:(fun () -> try Eio.Flow.shutdown flow `All with _ -> ())
    (fun () -> client_action clock flow closed_stats)

let test_h1_server_connection_get_fixed_response () =
  let seen_request, resolve_seen_request = Eio.Promise.create () in
  let handler (request : Eta_http.Server.Request.t) =
    ignore
      (Eio.Promise.try_resolve resolve_seen_request
         ( request.method_,
           request.path,
           request.version,
           request.scheme,
           request.authority,
           request.connection_id ));
    Eta.Effect.pure (Eta_http.Server.Response.text "hello\n")
  in
  with_h1_connection handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    "GET /hello?secret=1 HTTP/1.1\r\nHost: example.test\r\n\r\n"
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  let method_, path, version, scheme, authority, connection_id =
    Eio.Promise.await seen_request
  in
  Alcotest.(check string) "response"
    "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nhello\n"
    response;
  Alcotest.(check string) "method" "GET" method_;
  Alcotest.(check string) "path" "/hello" path;
  Alcotest.(check string) "version" "http/1.1"
    (Eta_http.Core.Version.to_string version);
  Alcotest.(check string) "scheme" "http" scheme;
  Alcotest.(check (option string)) "authority" (Some "example.test") authority;
  Alcotest.(check string) "connection id" "h1-test-connection" connection_id;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 1 stats.completed_requests;
  Alcotest.(check int) "protocol errors" 0 stats.protocol_errors

let test_h1_server_connection_post_reads_fixed_body () =
  let seen_body, resolve_seen_body = Eio.Promise.create () in
  let handler (request : Eta_http.Server.Request.t) =
    Eta_http.Server.Body.read_all request.body
    |> Eta.Effect.map (fun body ->
           ignore (Eio.Promise.try_resolve resolve_seen_body body);
           Eta_http.Server.Response.make ~status:200
             ~body:(Eta_http.Server.Response.Body.fixed [ body ])
             ())
  in
  with_h1_connection handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    ("POST /echo HTTP/1.1\r\nHost: example.test\r\n"
   ^ "Content-Length: 11\r\n\r\nhello-world")
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  let body = Eio.Promise.await seen_body in
  Alcotest.(check string) "handler body" "hello-world" (Bytes.to_string body);
  Alcotest.(check string) "response"
    "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhello-world"
    response;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "request bytes" 11 stats.request_bytes;
  Alcotest.(check int) "completed requests" 1 stats.completed_requests
