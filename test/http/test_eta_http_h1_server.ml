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

let read_exact_string flow length =
  let buffer = Buffer.create length in
  let scratch = Cstruct.create length in
  let rec loop off =
    if off = length then Buffer.contents buffer
    else
      let read =
        Eio.Flow.single_read flow (Cstruct.sub scratch 0 (length - off))
      in
      if read = 0 then Alcotest.fail "unexpected EOF while reading response";
      Buffer.add_string buffer (Cstruct.to_string (Cstruct.sub scratch 0 read));
      loop (off + read)
  in
  loop 0

let with_h1_connection ?time ?(config = Eta_http_eio.Server.Config.default)
    handler client_action =
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
        ?time ~flow:(flow :> Eta_http_eio.H1.Server_connection.flow)
        ~connection ~config ~runtime_factory
        ~on_close:(fun stats ->
          ignore (Eio.Promise.try_resolve resolve_closed_stats stats))
        handler);
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  Fun.protect
    ~finally:(fun () -> try Eio.Flow.shutdown flow `All with _ -> ())
    (fun () -> client_action clock flow closed_stats)

let run_h1_connection_on_flow ?(config = Eta_http_eio.Server.Config.default) flow
    handler =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let connection : Eta_http_eio.Server.Connection_info.t =
    {
      id = "h1-mock-connection";
      peer = { address = Some "127.0.0.1"; port = Some 8080 };
      protocol = Eta_http.Server.Error.H1;
      tls = false;
      alpn_protocol = None;
    }
  in
  let runtime_factory ~sw ~connection:_ () =
    Eta_eio.Runtime.create ~sw ~clock ()
  in
  let closed_stats = ref None in
  Eta_http_eio.H1.Server_connection.run ~sw ~clock
    ~flow:(flow :> Eta_http_eio.H1.Server_connection.flow)
    ~connection ~config ~runtime_factory
    ~on_close:(fun stats -> closed_stats := Some stats)
    handler;
  match !closed_stats with
  | Some stats -> stats
  | None -> Alcotest.fail "missing close stats"

let stream_body ?length ?(release = fun () -> Eta.Effect.unit) chunks =
  let chunks = ref chunks in
  Eta_http.Server.Response.Body.stream ?length ~release (fun () ->
      match !chunks with
      | [] -> Eta.Effect.pure None
      | chunk :: rest ->
          chunks := rest;
          Eta.Effect.pure (Some (Bytes.of_string chunk)))

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
    ("GET /hello?secret=1 HTTP/1.1\r\nHost: example.test\r\n"
   ^ "Connection: close\r\n\r\n")
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  let method_, path, version, scheme, authority, connection_id =
    Eio.Promise.await seen_request
  in
  Alcotest.(check string) "response"
    "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 6\r\n\r\nhello\n"
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
    ("POST /echo HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n"
   ^ "Content-Length: 11\r\n\r\nhello-world")
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  let body = Eio.Promise.await seen_body in
  Alcotest.(check string) "handler body" "hello-world" (Bytes.to_string body);
  Alcotest.(check string) "response"
    "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 11\r\n\r\nhello-world"
    response;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "request bytes" 11 stats.request_bytes;
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_connection_expect_100_continue_reads_body () =
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
  let interim = "HTTP/1.1 100 Continue\r\n\r\n" in
  Eio.Flow.copy_string
    ("POST /continue HTTP/1.1\r\nHost: example.test\r\n"
   ^ "Connection: close\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n")
    flow;
  Alcotest.(check string) "interim continue" interim
    (Eio.Time.with_timeout_exn clock 1.0 (fun () ->
         read_exact_string flow (String.length interim)));
  Eio.Flow.copy_string "hello" flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  let body = Eio.Promise.await seen_body in
  Alcotest.(check string) "handler body" "hello" (Bytes.to_string body);
  Alcotest.(check string) "response"
    "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 5\r\n\r\nhello"
    response;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "request bytes" 5 stats.request_bytes;
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_connection_expect_allows_early_final_response () =
  let handler (_request : Eta_http.Server.Request.t) =
    Eta.Effect.pure (Eta_http.Server.Response.text ~status:413 "too large\n")
  in
  with_h1_connection handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    ("POST /reject HTTP/1.1\r\nHost: example.test\r\n"
   ^ "Expect: 100-continue\r\nContent-Length: 5\r\n\r\n")
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check string) "response"
    ("HTTP/1.1 413 Payload Too Large\r\nConnection: close\r\n"
   ^ "Content-Length: 10\r\n\r\ntoo large\n")
    response;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "request bytes" 0 stats.request_bytes;
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_connection_rejects_unsupported_expectation () =
  let handler_called = ref false in
  let handler (_request : Eta_http.Server.Request.t) =
    handler_called := true;
    Eta.Effect.pure (Eta_http.Server.Response.text "unexpected\n")
  in
  with_h1_connection handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    ("POST /expect HTTP/1.1\r\nHost: example.test\r\n"
   ^ "Expect: storage-quota\r\nContent-Length: 5\r\n\r\n")
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check string) "response"
    ("HTTP/1.1 417 Expectation Failed\r\nConnection: close\r\n"
   ^ "Content-Length: 19\r\n\r\nexpectation failed\n")
    response;
  Alcotest.(check bool) "handler not called" false !handler_called;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 0 stats.completed_requests;
  Alcotest.(check int) "protocol errors" 1 stats.protocol_errors

let check_bad_request_rejected ?(response_prefix = "HTTP/1.1 400 Bad Request")
    ~name wire =
  let handler_called = ref false in
  let handler (_request : Eta_http.Server.Request.t) =
    handler_called := true;
    Eta.Effect.pure (Eta_http.Server.Response.text "unexpected\n")
  in
  with_h1_connection handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string wire flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check bool)
    (name ^ " response")
    true
    (String.starts_with ~prefix:response_prefix response);
  Alcotest.(check bool) (name ^ " handler not called") false !handler_called;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) (name ^ " completed requests") 0 stats.completed_requests;
  Alcotest.(check int) (name ^ " protocol errors") 1 stats.protocol_errors

let test_h1_server_connection_rejects_missing_http11_host () =
  check_bad_request_rejected ~name:"missing host"
    "GET /missing HTTP/1.1\r\nConnection: close\r\n\r\n"

let test_h1_server_connection_rejects_duplicate_http11_host () =
  check_bad_request_rejected ~name:"duplicate host"
    ("GET /duplicate HTTP/1.1\r\nHost: example.test\r\n"
   ^ "Host: shadow.test\r\nConnection: close\r\n\r\n")

let test_h1_server_connection_rejects_duplicate_content_length () =
  check_bad_request_rejected ~name:"duplicate content-length"
    ("POST /duplicate-cl HTTP/1.1\r\nHost: example.test\r\n"
   ^ "Content-Length: 5\r\nContent-Length: 5\r\nConnection: close\r\n\r\n"
   ^ "hello")

let test_h1_server_connection_rejects_http10_transfer_encoding () =
  check_bad_request_rejected
    ~response_prefix:"HTTP/1.0 400 Bad Request"
    ~name:"http10 transfer-encoding"
    ("POST /h10-te HTTP/1.0\r\nTransfer-Encoding: chunked\r\n"
   ^ "Connection: close\r\n\r\n0\r\n\r\n")

let test_h1_server_connection_rejects_invalid_http11_host () =
  check_bad_request_rejected ~name:"invalid host"
    "GET /invalid HTTP/1.1\r\nHost: bad/name\r\nConnection: close\r\n\r\n"

let test_h1_server_connection_rejects_bare_cr_request_line () =
  check_bad_request_rejected ~name:"bare cr request line"
    "GET / HTTP/1.1\rHost: example.test\r\nConnection: close\r\n\r\n"

let test_h1_server_connection_allows_http10_without_host () =
  let handler (request : Eta_http.Server.Request.t) =
    Eta.Effect.pure (Eta_http.Server.Response.text request.path)
  in
  with_h1_connection handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string "GET /h10 HTTP/1.0\r\n\r\n" flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check string) "response"
    "HTTP/1.0 200 OK\r\nConnection: close\r\nContent-Length: 4\r\n\r\n/h10"
    response;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 1 stats.completed_requests;
  Alcotest.(check int) "protocol errors" 0 stats.protocol_errors

let test_h1_server_connection_rejects_invalid_request_targets () =
  [
    ( "relative target",
      "GET noslash HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n"
    );
    ( "fragment target",
      "GET /path#frag HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n"
    );
    ( "asterisk target",
      "GET * HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n" );
    ( "connect target",
      "CONNECT /proxy HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n"
    );
  ]
  |> List.iter (fun (name, wire) -> check_bad_request_rejected ~name wire)

let test_h1_server_connection_rejects_header_smuggling_vectors () =
  [
    ( "obs-fold continuation",
      "GET / HTTP/1.1\r\nHost: example.test\r\nX-Fold: a\r\n\tb\r\n"
   ^ "Connection: close\r\n\r\n" );
    ( "leading space before header name",
      "GET / HTTP/1.1\r\nHost: example.test\r\n X-Bad: 1\r\n"
   ^ "Connection: close\r\n\r\n" );
    ( "space before colon in header name",
      "GET / HTTP/1.1\r\nHost: example.test\r\nX-Bad : 1\r\n"
   ^ "Connection: close\r\n\r\n" );
    ( "tab inside header name",
      "GET / HTTP/1.1\r\nHost: example.test\r\nX\tBad: 1\r\n"
   ^ "Connection: close\r\n\r\n" );
    ( "bare CR in header value",
      "GET / HTTP/1.1\r\nHost: example.test\r\nX-Bad: a\rb\r\n"
   ^ "Connection: close\r\n\r\n" );
    ( "NUL in header value",
      "GET / HTTP/1.1\r\nHost: example.test\r\nX-Bad: a\x00b\r\n"
   ^ "Connection: close\r\n\r\n" );
  ]
  |> List.iter (fun (name, wire) -> check_bad_request_rejected ~name wire)

let test_h1_server_connection_accepts_options_asterisk_target () =
  let handler (request : Eta_http.Server.Request.t) =
    Eta.Effect.pure (Eta_http.Server.Response.text request.target)
  in
  with_h1_connection handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    "OPTIONS * HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n"
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check string) "response"
    "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 1\r\n\r\n*"
    response;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 1 stats.completed_requests;
  Alcotest.(check int) "protocol errors" 0 stats.protocol_errors

let test_h1_server_connection_normalizes_absolute_form_target () =
  let seen_request, resolve_seen_request = Eio.Promise.create () in
  let handler (request : Eta_http.Server.Request.t) =
    ignore
      (Eio.Promise.try_resolve resolve_seen_request
         (request.target, request.path, request.query, request.authority));
    Eta.Effect.pure (Eta_http.Server.Response.text request.path)
  in
  with_h1_connection handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    ("GET http://example.test/absolute?x=1 HTTP/1.1\r\n"
   ^ "Host: example.test:80\r\nConnection: close\r\n\r\n")
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  let target, path, query, authority = Eio.Promise.await seen_request in
  Alcotest.(check string) "response"
    ("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 9\r\n\r\n"
   ^ "/absolute")
    response;
  Alcotest.(check string) "target" "/absolute?x=1" target;
  Alcotest.(check string) "path" "/absolute" path;
  Alcotest.(check (option string)) "query" (Some "x=1") query;
  Alcotest.(check (option string)) "authority" (Some "example.test") authority;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 1 stats.completed_requests;
  Alcotest.(check int) "protocol errors" 0 stats.protocol_errors

let test_h1_server_connection_rejects_absolute_form_host_conflict () =
  check_bad_request_rejected ~name:"absolute host conflict"
    ("GET http://example.test/conflict HTTP/1.1\r\nHost: shadow.test\r\n"
   ^ "Connection: close\r\n\r\n")

let test_h1_server_connection_post_reads_chunked_body_and_trailers () =
  let seen, resolve_seen = Eio.Promise.create () in
  let handler (request : Eta_http.Server.Request.t) =
    Eta_http.Server.Body.read_all request.body
    |> Eta.Effect.bind (fun body ->
           request.trailers ()
           |> Eta.Effect.map (fun trailers ->
                  let trailer =
                    Option.value ~default:"missing"
                      (Eta_http.Core.Header.get "x-checksum" trailers)
                  in
                  ignore
                    (Eio.Promise.try_resolve resolve_seen
                       (Bytes.to_string body, trailer));
                  Eta_http.Server.Response.text
                    (Bytes.to_string body ^ "|" ^ trailer)))
  in
  with_h1_connection handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    ("POST /echo HTTP/1.1\r\nHost: example.test\r\n"
   ^ "Connection: close\r\nTransfer-Encoding: chunked\r\n"
   ^ "Trailer: X-Checksum\r\n\r\n"
   ^ "5\r\nhello\r\n6\r\n-world\r\n0\r\nX-Checksum: ok\r\n\r\n")
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  let body, trailer = Eio.Promise.await seen in
  Alcotest.(check string) "handler body" "hello-world" body;
  Alcotest.(check string) "handler trailer" "ok" trailer;
  Alcotest.(check string) "response"
    "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 14\r\n\r\nhello-world|ok"
    response;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "request bytes" 11 stats.request_bytes;
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_connection_rejects_invalid_chunked_body () =
  let handler (request : Eta_http.Server.Request.t) =
    Eta_http.Server.Body.read_all request.body
    |> Eta.Effect.map (fun _ -> Eta_http.Server.Response.text "unexpected\n")
  in
  with_h1_connection handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    ("POST /echo HTTP/1.1\r\nHost: example.test\r\n"
   ^ "Connection: close\r\nTransfer-Encoding: chunked\r\n\r\n"
   ^ "z\r\nboom\r\n0\r\n\r\n")
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check bool) "bad request"
    true
    (String.starts_with ~prefix:"HTTP/1.1 400 Bad Request" response);
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_connection_rejects_oversized_chunked_trailers () =
  let server_limits =
    { Eta_http.Server.Config.default.limits with max_trailer_bytes = 8 }
  in
  let server_config =
    { Eta_http.Server.Config.default with limits = server_limits }
  in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  let handler (request : Eta_http.Server.Request.t) =
    Eta_http.Server.Body.read_all request.body
    |> Eta.Effect.map (fun _ -> Eta_http.Server.Response.text "unexpected\n")
  in
  with_h1_connection ~config handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    ("POST /echo HTTP/1.1\r\nHost: example.test\r\n"
   ^ "Connection: close\r\nTransfer-Encoding: chunked\r\n\r\n"
   ^ "0\r\nX-Too-Large: value\r\n\r\n")
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check bool) "bad request"
    true
    (String.starts_with ~prefix:"HTTP/1.1 400 Bad Request" response);
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_connection_request_body_timeout () =
  let server_timeouts =
    {
      Eta_http.Server.Config.default.timeouts with
      request_body_timeout = Some (Eta.Duration.ms 50);
    }
  in
  let server_config =
    { Eta_http.Server.Config.default with timeouts = server_timeouts }
  in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  let handler (request : Eta_http.Server.Request.t) =
    Eta_http.Server.Body.read_all request.body
    |> Eta.Effect.map (fun _ -> Eta_http.Server.Response.text "unexpected\n")
  in
  with_h1_connection ~config handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    ("POST /slow HTTP/1.1\r\nHost: example.test\r\n"
   ^ "Connection: close\r\nContent-Length: 5\r\n\r\nhe")
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check bool) "request timeout"
    true
    (String.starts_with ~prefix:"HTTP/1.1 408 Request Timeout" response);
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_connection_handler_timeout () =
  let timeouts =
    {
      Eta_http.Server.Config.default.timeouts with
      handler_timeout = Some (Eta.Duration.ms 20);
    }
  in
  let server_config = { Eta_http.Server.Config.default with timeouts } in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  let clock_ref = ref None in
  let handler (_request : Eta_http.Server.Request.t) =
    match !clock_ref with
    | None -> Alcotest.fail "handler clock not initialized"
    | Some clock ->
        Eta.Effect.sync (fun () ->
            Eio.Time.sleep clock 1.0;
            Eta_http.Server.Response.text "late\n")
  in
  with_h1_connection ~config handler @@ fun clock flow closed_stats ->
  clock_ref := Some clock;
  Eio.Flow.copy_string
    "GET /slow-handler HTTP/1.1\r\nHost: example.test\r\n\r\n" flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check string) "response"
    ("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n"
   ^ "Content-Length: 20\r\n\r\nservice unavailable\n")
    response;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_connection_handler_construction_timeout () =
  let timeouts =
    {
      Eta_http.Server.Config.default.timeouts with
      handler_timeout = Some (Eta.Duration.ms 20);
    }
  in
  let server_config = { Eta_http.Server.Config.default with timeouts } in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  let clock_ref = ref None in
  let handler (_request : Eta_http.Server.Request.t) =
    match !clock_ref with
    | None -> Alcotest.fail "handler clock not initialized"
    | Some clock ->
        Eio.Time.sleep clock 1.0;
        Eta.Effect.pure (Eta_http.Server.Response.text "late\n")
  in
  with_h1_connection ~config handler @@ fun clock flow closed_stats ->
  clock_ref := Some clock;
  Eio.Flow.copy_string
    ("GET /slow-handler HTTP/1.1\r\nHost: example.test\r\n\r\n"
   ^ "GET /after HTTP/1.1\r\nHost: example.test\r\n\r\n")
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check string) "response"
    ("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n"
   ^ "Content-Length: 20\r\n\r\nservice unavailable\n")
    response;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_connection_handler_timeout_uses_injected_time () =
  let timeouts =
    {
      Eta_http.Server.Config.default.timeouts with
      handler_timeout = Some (Eta.Duration.ms 20);
    }
  in
  let server_config = { Eta_http.Server.Config.default with timeouts } in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  let time : Eta_http_eio.Server.time =
    {
      now_ms = (fun () -> 0L);
      sleep = (fun _duration -> ());
      with_timeout =
        (fun duration f ->
          if Eta.Duration.to_ms duration = 20 then raise Eio.Time.Timeout
          else f ());
    }
  in
  let handler_called = ref false in
  let handler (_request : Eta_http.Server.Request.t) =
    handler_called := true;
    Eta.Effect.pure (Eta_http.Server.Response.text "late\n")
  in
  with_h1_connection ~time ~config handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    "GET /controlled-handler-timeout HTTP/1.1\r\nHost: example.test\r\n\r\n"
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check string) "response"
    ("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n"
   ^ "Content-Length: 20\r\n\r\nservice unavailable\n")
    response;
  Alcotest.(check bool) "handler not constructed" false !handler_called;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_connection_streams_fixed_length_response () =
  let released = ref 0 in
  let handler (_request : Eta_http.Server.Request.t) =
    let body =
      stream_body ~length:5
        ~release:(fun () ->
          incr released;
          Eta.Effect.unit)
        [ "he"; "llo" ]
    in
    Eta.Effect.pure
      (Eta_http.Server.Response.make ~status:200 ~body ())
  in
  with_h1_connection handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    ("GET /stream-fixed HTTP/1.1\r\nHost: example.test\r\n"
   ^ "Connection: close\r\n\r\n")
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check string) "response"
    "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 5\r\n\r\nhello"
    response;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "released" 1 !released;
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_connection_streams_chunked_response_with_trailers () =
  let released = ref 0 in
  let handler (_request : Eta_http.Server.Request.t) =
    let body =
      stream_body
        ~release:(fun () ->
          incr released;
          Eta.Effect.unit)
        [ "ab"; "c" ]
    in
    Eta.Effect.pure
      (Eta_http.Server.Response.make ~status:200
         ~headers:[ ("Trailer", "X-Done") ]
         ~trailers:(fun () -> Eta.Effect.pure [ ("X-Done", "yes") ])
         ~body ())
  in
  with_h1_connection handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    ("GET /stream-chunked HTTP/1.1\r\nHost: example.test\r\n"
   ^ "Connection: close\r\n\r\n")
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check string) "response"
    ("HTTP/1.1 200 OK\r\nTrailer: X-Done\r\n"
   ^ "Connection: close\r\n"
   ^ "Transfer-Encoding: chunked\r\n\r\n"
   ^ "2\r\nab\r\n1\r\nc\r\n0\r\nX-Done: yes\r\n\r\n")
    response;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "released" 1 !released;
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_connection_releases_stream_on_write_failure () =
  let flow = Eio_mock.Flow.make "eta-http-h1-server-stream-write-fail" in
  Eio_mock.Flow.on_read flow
    [ `Return "GET /stream HTTP/1.1\r\nHost: example.test\r\n\r\n" ];
  Eio_mock.Flow.on_copy_bytes flow
    [ `Return 4096; `Raise (Failure "response write failed") ];
  let released = ref 0 in
  let handler (_request : Eta_http.Server.Request.t) =
    let body =
      stream_body
        ~release:(fun () ->
          incr released;
          Eta.Effect.unit)
        [ "first"; "second" ]
    in
    Eta.Effect.pure
      (Eta_http.Server.Response.make ~status:200 ~body ())
  in
  let stats = run_h1_connection_on_flow flow handler in
  Alcotest.(check int) "released" 1 !released;
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_connection_response_write_timeout_is_typed () =
  let timeouts =
    {
      Eta_http.Server.Config.default.timeouts with
      response_write_timeout = Some (Eta.Duration.ms 1);
    }
  in
  let server_config = { Eta_http.Server.Config.default with timeouts } in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  let flow = Eio_mock.Flow.make "eta-http-h1-server-write-timeout" in
  Eio_mock.Flow.on_read flow
    [ `Return "GET /timeout HTTP/1.1\r\nHost: example.test\r\n\r\n" ];
  Eio_mock.Flow.on_copy_bytes flow [ `Raise Eio.Time.Timeout ];
  let handler (_request : Eta_http.Server.Request.t) =
    Eta.Effect.pure (Eta_http.Server.Response.text "slow-client\n")
  in
  let stats = run_h1_connection_on_flow ~config flow handler in
  Alcotest.(check int) "completed requests" 1 stats.completed_requests;
  Alcotest.(check int) "response bytes" 0 stats.response_bytes

let test_h1_server_connection_response_body_timeout_releases_stream () =
  let timeouts =
    {
      Eta_http.Server.Config.default.timeouts with
      response_body_timeout = Some (Eta.Duration.ms 20);
    }
  in
  let server_config = { Eta_http.Server.Config.default with timeouts } in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  let released = ref 0 in
  let clock_ref = ref None in
  let handler (_request : Eta_http.Server.Request.t) =
    let body =
      Eta_http.Server.Response.Body.stream
        ~release:(fun () ->
          incr released;
          Eta.Effect.unit)
        (fun () ->
          match !clock_ref with
          | None -> Alcotest.fail "handler clock not initialized"
          | Some clock ->
              Eta.Effect.sync (fun () ->
                  Eio.Time.sleep clock 1.0;
                  Some (Bytes.of_string "late")))
    in
    Eta.Effect.pure (Eta_http.Server.Response.make ~status:200 ~body ())
  in
  with_h1_connection ~config handler @@ fun clock flow closed_stats ->
  clock_ref := Some clock;
  Eio.Flow.copy_string
    ("GET /slow-response-body HTTP/1.1\r\nHost: example.test\r\n"
   ^ "Connection: close\r\n\r\n")
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check string) "response head"
    ("HTTP/1.1 200 OK\r\nConnection: close\r\n"
   ^ "Transfer-Encoding: chunked\r\n\r\n")
    response;
  Alcotest.(check int) "released" 1 !released;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_connection_rejects_response_header_limit () =
  let server_limits =
    { Eta_http.Server.Config.default.limits with max_response_headers = 1 }
  in
  let server_config =
    { Eta_http.Server.Config.default with limits = server_limits }
  in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  let handler (_request : Eta_http.Server.Request.t) =
    Eta.Effect.pure
      (Eta_http.Server.Response.text
         ~headers:[ ("X-One", "1"); ("X-Two", "2") ]
         "too many headers\n")
  in
  with_h1_connection ~config handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    "GET /too-many-response-headers HTTP/1.1\r\nHost: example.test\r\n\r\n"
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check string) "response"
    ("HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\n"
   ^ "Content-Length: 22\r\n\r\ninternal server error\n")
    response;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let path_response (request : Eta_http.Server.Request.t) =
  Eta.Effect.pure (Eta_http.Server.Response.text request.path)

let test_h1_server_connection_keeps_alive_for_sequential_requests () =
  with_h1_connection path_response @@ fun clock flow closed_stats ->
  let first =
    "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n/one"
  in
  let second =
    "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 4\r\n\r\n/two"
  in
  Eio.Flow.copy_string
    "GET /one HTTP/1.1\r\nHost: example.test\r\n\r\n"
    flow;
  Alcotest.(check string) "first response" first
    (Eio.Time.with_timeout_exn clock 1.0 (fun () ->
         read_exact_string flow (String.length first)));
  Eio.Flow.copy_string
    "GET /two HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n"
    flow;
  Alcotest.(check string) "second response" second
    (Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow));
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 2 stats.completed_requests

let test_h1_server_connection_http10_defaults_to_close () =
  with_h1_connection path_response @@ fun clock flow closed_stats ->
  let response =
    "HTTP/1.0 200 OK\r\nConnection: close\r\nContent-Length: 4\r\n\r\n/h10"
  in
  Eio.Flow.copy_string "GET /h10 HTTP/1.0\r\n\r\n" flow;
  Alcotest.(check string) "response" response
    (Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow));
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 1 stats.completed_requests;
  Alcotest.(check int) "protocol errors" 0 stats.protocol_errors

let test_h1_server_connection_explicit_close_header () =
  with_h1_connection path_response @@ fun clock flow closed_stats ->
  let response =
    "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 6\r\n\r\n/close"
  in
  Eio.Flow.copy_string
    "GET /close HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n"
    flow;
  Alcotest.(check string) "response" response
    (Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow));
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_connection_keeps_pipelined_request_bytes () =
  with_h1_connection path_response @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    ("GET /one HTTP/1.1\r\nHost: example.test\r\n\r\n"
   ^ "GET /two HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n")
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check string) "response"
    ("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n/one"
   ^ "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 4\r\n\r\n/two")
    response;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 2 stats.completed_requests

let test_h1_server_connection_drains_unread_body_for_reuse () =
  let server = Eta_http_eio.Server.Config.default in
  let config =
    {
      server with
      server =
        {
          server.server with
          unread_body_policy = Eta_http.Server.Config.Drain_up_to 4;
        };
    }
  in
  let handler (request : Eta_http.Server.Request.t) =
    let text =
      if String.equal request.path "/early" then "early\n" else "after\n"
    in
    Eta.Effect.pure (Eta_http.Server.Response.text text)
  in
  with_h1_connection ~config handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    ("POST /early HTTP/1.1\r\nHost: example.test\r\nContent-Length: 4\r\n\r\n"
   ^ "dataGET /after HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n")
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check string) "response"
    ("HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nearly\n"
   ^ "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 6\r\n\r\nafter\n")
    response;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "request bytes" 4 stats.request_bytes;
  Alcotest.(check int) "completed requests" 2 stats.completed_requests

let test_h1_server_connection_head_discards_body_preserves_content_length () =
  let handler (_request : Eta_http.Server.Request.t) =
    Eta.Effect.pure
      (Eta_http.Server.Response.make ~status:200
         ~body:(Eta_http.Server.Response.Body.fixed [ Bytes.of_string "body-content" ])
         ())
  in
  with_h1_connection handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    "HEAD /head HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n"
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check string) "response"
    ("HTTP/1.1 200 OK\r\nConnection: close\r\n"
   ^ "Content-Length: 12\r\n\r\n")
    response;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_connection_no_content_releases_suppressed_stream () =
  let released = ref 0 in
  let handler (_request : Eta_http.Server.Request.t) =
    let body =
      stream_body
        ~release:(fun () ->
          incr released;
          Eta.Effect.unit)
        [ "must-not-write" ]
    in
    Eta.Effect.pure (Eta_http.Server.Response.make ~status:204 ~body ())
  in
  with_h1_connection handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    "GET /no-content HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n"
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check string) "response"
    "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
    response;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "released" 1 !released;
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_connection_reset_content_releases_suppressed_stream () =
  let released = ref 0 in
  let handler (_request : Eta_http.Server.Request.t) =
    let body =
      stream_body
        ~release:(fun () ->
          incr released;
          Eta.Effect.unit)
        [ "must-not-write" ]
    in
    Eta.Effect.pure (Eta_http.Server.Response.make ~status:205 ~body ())
  in
  with_h1_connection handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    "GET /reset-content HTTP/1.1\r\nHost: example.test\r\nConnection: \
     close\r\n\r\n"
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check string) "response"
    "HTTP/1.1 205 Reset Content\r\nConnection: close\r\n\r\n"
    response;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "released" 1 !released;
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_connection_head_matches_get_content_length () =
  let handler (_request : Eta_http.Server.Request.t) =
    Eta.Effect.pure
      (Eta_http.Server.Response.make ~status:200
         ~body:
           (Eta_http.Server.Response.Body.fixed [ Bytes.of_string "response-body" ])
         ())
  in
  (* Exercise HEAD and GET separately so the raw helper can read each response
     to EOF. *)
  with_h1_connection handler @@ fun clock flow closed_stats ->
  let head_response =
    "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 13\r\n\r\n"
  in
  Eio.Flow.copy_string
    "HEAD /head-get HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n"
    flow;
  Alcotest.(check string) "HEAD response" head_response
    (Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow));
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 1 stats.completed_requests;
  with_h1_connection handler @@ fun clock flow closed_stats ->
  let get_response =
    "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 13\r\n\r\nresponse-body"
  in
  Eio.Flow.copy_string
    "GET /head-get HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n"
    flow;
  Alcotest.(check string) "GET response" get_response
    (Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow));
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_connection_head_explicit_handler_wins () =
  let handler (request : Eta_http.Server.Request.t) =
    if String.equal request.method_ "HEAD" then
      Eta.Effect.pure
        (Eta_http.Server.Response.make ~status:200
           ~headers:[ ("X-Explicit-Head", "true") ]
           ~body:Eta_http.Server.Response.Body.empty ())
    else
      Eta.Effect.pure
        (Eta_http.Server.Response.make ~status:200
           ~body:(Eta_http.Server.Response.Body.fixed [ Bytes.of_string "get-body" ])
           ())
  in
  with_h1_connection handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    "HEAD /explicit-head HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n"
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check string) "response"
    ("HTTP/1.1 200 OK\r\nX-Explicit-Head: true\r\nConnection: close\r\n"
   ^ "Content-Length: 0\r\n\r\n")
    response;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_connection_request_line_too_large () =
  (* Eta maps H1 parse-limit failures to 400 while still enforcing the request
     line limit. *)
  let handler (_request : Eta_http.Server.Request.t) =
    Eta.Effect.pure (Eta_http.Server.Response.text "unexpected\n")
  in
  let server_limits =
    { Eta_http.Server.Config.default.limits with max_request_line_bytes = 16 }
  in
  let server_config =
    { Eta_http.Server.Config.default with limits = server_limits }
  in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  with_h1_connection ~config handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    "GET /long-request-target HTTP/1.1\r\nHost: example.test\r\n\r\n"
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check bool) "response is 400"
    true
    (String.starts_with ~prefix:"HTTP/1.1 400 Bad Request" response);
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 0 stats.completed_requests;
  Alcotest.(check int) "protocol errors" 1 stats.protocol_errors

let test_h1_server_connection_header_section_too_large () =
  (* Eta maps H1 parse-limit failures to 400 while still enforcing the header
     section limit. *)
  let handler (_request : Eta_http.Server.Request.t) =
    Eta.Effect.pure (Eta_http.Server.Response.text "unexpected\n")
  in
  let server_limits =
    { Eta_http.Server.Config.default.limits with max_request_header_bytes = 16 }
  in
  let server_config =
    { Eta_http.Server.Config.default with limits = server_limits }
  in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  with_h1_connection ~config handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    "GET /big-headers HTTP/1.1\r\nHost: example.test\r\nX-Large: value\r\n\r\n"
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check bool) "response is 400"
    true
    (String.starts_with ~prefix:"HTTP/1.1 400 Bad Request" response);
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 0 stats.completed_requests;
  Alcotest.(check int) "protocol errors" 1 stats.protocol_errors

let test_h1_server_connection_keeps_chunked_pipelined_bytes () =
  let handler (request : Eta_http.Server.Request.t) =
    if String.equal request.path "/echo" then
      Eta_http.Server.Body.read_all request.body
      |> Eta.Effect.map (fun body ->
             Eta_http.Server.Response.make ~status:200
               ~body:(Eta_http.Server.Response.Body.fixed [ body ])
               ())
    else Eta.Effect.pure (Eta_http.Server.Response.text "after\n")
  in
  with_h1_connection handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    ("POST /echo HTTP/1.1\r\nHost: example.test\r\n"
   ^ "Transfer-Encoding: chunked\r\n\r\n"
   ^ "5\r\nhello\r\n0\r\n\r\n"
   ^ "GET /after HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n")
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check string) "response"
    ("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
   ^ "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 6\r\n\r\nafter\n")
    response;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "request bytes" 5 stats.request_bytes;
  Alcotest.(check int) "completed requests" 2 stats.completed_requests

let test_h1_server_connection_idle_timeout_closes_keep_alive () =
  let server = Eta_http_eio.Server.Config.default in
  let config =
    {
      server with
      server =
        {
          server.server with
          timeouts =
            {
              server.server.timeouts with
              idle_timeout = Some (Eta.Duration.ms 20);
            };
        };
    }
  in
  with_h1_connection ~config path_response @@ fun clock flow closed_stats ->
  let response =
    "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n/idle"
  in
  Eio.Flow.copy_string
    "GET /idle HTTP/1.1\r\nHost: example.test\r\n\r\n"
    flow;
  Alcotest.(check string) "response" response
    (Eio.Time.with_timeout_exn clock 1.0 (fun () ->
         read_exact_string flow (String.length response)));
  Alcotest.(check string) "idle close" ""
    (Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow));
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_run_on_socket_plain_get () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let stop, resolve_stop = Eio.Promise.create () in
  let seen_request, resolve_seen_request = Eio.Promise.create () in
  let closed_stats, resolve_closed_stats = Eio.Promise.create () in
  let on_connection_close stats =
    ignore (Eio.Promise.try_resolve resolve_closed_stats stats);
    ignore (Eio.Promise.try_resolve resolve_stop ())
  in
  let handler (request : Eta_http.Server.Request.t) =
    ignore
      (Eio.Promise.try_resolve resolve_seen_request
         ( request.path,
           request.scheme,
           request.tls,
           request.alpn_protocol,
           request.connection_id ));
    Eta.Effect.pure (Eta_http.Server.Response.text "plain-h1\n")
  in
  Eio.Fiber.fork ~sw (fun () ->
      Eta_http_eio.Server.run_h1_on_socket ~sw ~clock ~stop
        ~on_connection_close ~socket handler);
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  Fun.protect
    ~finally:(fun () -> try Eio.Flow.shutdown flow `All with _ -> ())
    (fun () ->
      Eio.Flow.copy_string
        ("GET /public HTTP/1.1\r\nHost: example.test\r\n"
       ^ "Connection: close\r\n\r\n")
        flow;
      let response =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            read_all_response flow)
      in
      Alcotest.(check string) "response"
        ("HTTP/1.1 200 OK\r\nConnection: close\r\n"
       ^ "Content-Length: 9\r\n\r\nplain-h1\n")
        response;
      let path, scheme, tls, alpn_protocol, connection_id =
        Eio.Promise.await seen_request
      in
      Alcotest.(check string) "path" "/public" path;
      Alcotest.(check string) "scheme" "http" scheme;
      Alcotest.(check bool) "tls" false tls;
      Alcotest.(check (option string)) "alpn" None alpn_protocol;
      Alcotest.(check bool) "connection id prefix" true
        (String.starts_with ~prefix:"h1-" connection_id);
      let stats =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            Eio.Promise.await closed_stats)
      in
      Alcotest.(check int) "completed requests" 1 stats.completed_requests)

let test_h1_server_run_on_unix_socket_plain_get () =
  let path = Filename.temp_file "eta-http-h1-unix" ".sock" in
  Sys.remove path;
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      run_eio @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.clock env in
      let socket = Eio.Net.listen ~sw ~backlog:1 net (`Unix path) in
      let stop, resolve_stop = Eio.Promise.create () in
      let seen_request, resolve_seen_request = Eio.Promise.create () in
      let closed_stats, resolve_closed_stats = Eio.Promise.create () in
      let on_connection_close stats =
        ignore (Eio.Promise.try_resolve resolve_closed_stats stats);
        ignore (Eio.Promise.try_resolve resolve_stop ())
      in
      let handler (request : Eta_http.Server.Request.t) =
        ignore
          (Eio.Promise.try_resolve resolve_seen_request
             (request.peer.address, request.peer.port, request.connection_id));
        Eta.Effect.pure (Eta_http.Server.Response.text "unix-h1\n")
      in
      Eio.Fiber.fork ~sw (fun () ->
          Eta_http_eio.Server.run_h1_on_socket ~sw ~clock ~stop
            ~on_connection_close ~socket handler);
      let flow = Eio.Net.connect ~sw net (`Unix path) in
      Fun.protect
        ~finally:(fun () -> try Eio.Flow.shutdown flow `All with _ -> ())
        (fun () ->
          Eio.Flow.copy_string
            ("GET /unix HTTP/1.1\r\nHost: unix.test\r\n"
           ^ "Connection: close\r\n\r\n")
            flow;
          let response =
            Eio.Time.with_timeout_exn clock 1.0 (fun () ->
                read_all_response flow)
          in
          Alcotest.(check string) "response"
            ("HTTP/1.1 200 OK\r\nConnection: close\r\n"
           ^ "Content-Length: 8\r\n\r\nunix-h1\n")
            response;
          let peer_address, peer_port, connection_id =
            Eio.Promise.await seen_request
          in
          Alcotest.(check bool) "peer address recorded" true
            (Option.is_some peer_address);
          Alcotest.(check (option int)) "peer port" None peer_port;
          Alcotest.(check bool) "connection id prefix" true
            (String.starts_with ~prefix:"h1-" connection_id);
          let stats =
            Eio.Time.with_timeout_exn clock 1.0 (fun () ->
                Eio.Promise.await closed_stats)
          in
          Alcotest.(check int) "completed requests" 1 stats.completed_requests))

let test_h1_server_handle_graceful_shutdown_waits_for_request () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:4 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let handler_started, resolve_handler_started = Eio.Promise.create () in
  let release_handler, resolve_release_handler = Eio.Promise.create () in
  let closed_stats, resolve_closed_stats = Eio.Promise.create () in
  let on_connection_close stats =
    ignore (Eio.Promise.try_resolve resolve_closed_stats stats)
  in
  let handler (request : Eta_http.Server.Request.t) =
    match request.path with
    | "/wait" ->
        Eta.Effect.sync (fun () ->
            ignore (Eio.Promise.try_resolve resolve_handler_started ());
            Eio.Promise.await release_handler;
            Eta_http.Server.Response.text "done\n")
    | _ -> Eta.Effect.pure (Eta_http.Server.Response.text "ok\n")
  in
  let server =
    Eta_http_eio.Server.start_h1_on_socket ~sw ~clock ~on_connection_close
      ~socket handler
  in
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Eio.Promise.try_resolve resolve_release_handler ());
      Eta_http_eio.Server.shutdown server Immediate;
      try Eio.Flow.shutdown flow `All with _ -> ())
    (fun () ->
      let response, resolve_response = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Flow.copy_string
            "GET /wait HTTP/1.1\r\nHost: example.test\r\n\r\n"
            flow;
          ignore
            (Eio.Promise.try_resolve resolve_response
               (read_all_response flow)));
      Eio.Time.with_timeout_exn clock 1.0 (fun () ->
          Eio.Promise.await handler_started);
      let stats = Eta_http_eio.Server.stats server in
      Alcotest.(check int) "active connections before shutdown" 1
        stats.active_connections;
      Alcotest.(check int) "opened connections before shutdown" 1
        stats.opened_connections;
      Alcotest.(check int) "closed connections before shutdown" 0
        stats.closed_connections;
      Eta_http_eio.Server.shutdown server (Graceful (Eta.Duration.ms 200));
      let closed_before_release =
        Eio.Fiber.first
          (fun () ->
            ignore (Eio.Promise.await closed_stats);
            true)
          (fun () ->
            Eio.Time.sleep clock 0.02;
            false)
      in
      Alcotest.(check bool) "graceful keeps active request open" false
        closed_before_release;
      ignore (Eio.Promise.try_resolve resolve_release_handler ());
      Alcotest.(check string) "response"
        "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 5\r\n\r\ndone\n"
        (Eio.Time.with_timeout_exn clock 1.0 (fun () ->
             Eio.Promise.await response));
      let connection_stats =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            Eio.Promise.await closed_stats)
      in
      Alcotest.(check int) "completed requests" 1
        connection_stats.completed_requests;
      let stats = Eta_http_eio.Server.stats server in
      Alcotest.(check int) "active connections after shutdown" 0
        stats.active_connections;
      Alcotest.(check int) "opened connections after shutdown" 1
        stats.opened_connections;
      Alcotest.(check int) "closed connections after shutdown" 1
        stats.closed_connections)

let metric_values name meter =
  Eta.Meter.dump meter
  |> List.filter_map (fun point ->
         if String.equal point.Eta.Meter.name name then Some point.value
         else None)

let has_metric name meter = metric_values name meter <> []

let has_int_metric name value meter =
  metric_values name meter
  |> List.exists (function Eta.Meter.Int actual -> actual = value | Float _ -> false)

let test_h1_server_connection_emits_meter_metrics () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let meter = Eta.Meter.in_memory () in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let closed_stats, resolve_closed_stats = Eio.Promise.create () in
  let runtime_factory ~sw ~connection:_ () =
    Eta_eio.Runtime.create ~sw ~clock
      ~meter:(Eta.Meter.as_capability meter) ()
  in
  let server_config =
    {
      Eta_http.Server.Config.default with
      unread_body_policy = Eta_http.Server.Config.Drain_up_to 4096;
    }
  in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  let handler (request : Eta_http.Server.Request.t) =
    Eta_http.Server.Body.read_all request.body
    |> Eta.Effect.map (fun _body ->
           Eta_http.Server.Response.make ~status:200
             ~body:
               (Eta_http.Server.Response.Body.fixed
                  [ Bytes.of_string "metric-ok" ])
             ())
  in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Switch.run @@ fun conn_sw ->
      let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
      let connection : Eta_http_eio.Server.Connection_info.t =
        {
          id = "h1-meter-connection";
          peer = { address = Some "127.0.0.1"; port = Some port };
          protocol = Eta_http.Server.Error.H1;
          tls = false;
          alpn_protocol = None;
        }
      in
      Eta_http_eio.H1.Server_connection.run ~sw:conn_sw ~clock
        ~flow:(flow :> Eta_http_eio.H1.Server_connection.flow)
        ~connection ~config ~runtime_factory
        ~on_close:(fun stats ->
          ignore (Eio.Promise.try_resolve resolve_closed_stats stats))
        handler);
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  Fun.protect
    ~finally:(fun () -> try Eio.Flow.shutdown flow `All with _ -> ())
    (fun () ->
      Eio.Flow.copy_string
        ("POST /metrics HTTP/1.1\r\nHost: example.test\r\n"
       ^ "Content-Length: 5\r\n\r\nhello"
       ^ "BOGUS\r\n\r\n")
        flow;
      let response =
        Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
      in
      Alcotest.(check bool) "response body present" true
        (String.contains response 'm');
      let stats =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            Eio.Promise.await closed_stats)
      in
      Alcotest.(check int) "completed requests" 1 stats.completed_requests;
      Alcotest.(check int) "protocol errors" 1 stats.protocol_errors;
      Alcotest.(check bool) "active connection metric" true
        (has_metric "eta_http.server.connections.active" meter);
      Alcotest.(check bool) "request total metric" true
        (has_int_metric "eta_http.server.requests.total" 1 meter);
      Alcotest.(check bool) "in-flight request metric" true
        (has_metric "eta_http.server.requests.in_flight" meter);
      Alcotest.(check bool) "request body bytes metric" true
        (has_int_metric "eta_http.server.request.body.bytes" 5 meter);
      Alcotest.(check bool) "response body bytes metric" true
        (has_int_metric "eta_http.server.response.body.bytes" 9 meter);
      Alcotest.(check bool) "protocol error metric" true
        (has_int_metric "eta_http.server.protocol.errors" 1 meter))

let read_h1_response flow =
  let br = Eio.Buf_read.of_flow ~max_size:65536 flow in
  let status_line = Eio.Buf_read.line br in
  let rec headers content_length =
    match Eio.Buf_read.line br with
    | "" -> content_length
    | line -> (
        match String.split_on_char ':' line with
        | name :: rest
          when String.lowercase_ascii (String.trim name) = "content-length" ->
            headers (int_of_string (String.trim (String.concat ":" rest)))
        | _ -> headers content_length)
  in
  let content_length = headers 0 in
  let body = Eio.Buf_read.take content_length br in
  let status =
    if String.length status_line >= 12 then String.sub status_line 9 3
    else ""
  in
  (int_of_string status, body)

let test_h1_server_handler_exception_returns_500 () =
  let handler (request : Eta_http.Server.Request.t) =
    if request.path = "/boom" then failwith "handler boom"
    else Eta.Effect.pure (Eta_http.Server.Response.text "ok\n")
  in
  with_h1_connection handler (fun clock flow _closed_stats ->
      Eio.Flow.copy_string
        "GET /boom HTTP/1.1\r\nHost: example.test\r\n\r\nGET /ok \
         HTTP/1.1\r\nHost: example.test\r\n\r\n"
        flow;
      let response =
        Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
      in
      Alcotest.(check string) "handler exception response"
        ("HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\n"
       ^ "Content-Length: 22\r\n\r\ninternal server error\n")
        response)

let test_h1_server_stream_response_releases_after_body_written () =
  (* zio-http HttpApp.test.ts "stream" - response stream finalization. *)
  let released = ref 0 in
  let handler (_request : Eta_http.Server.Request.t) =
    let body =
      stream_body
        ~release:(fun () ->
          incr released;
          Eta.Effect.unit)
        [ "chunk-a"; "chunk-b" ]
    in
    Eta.Effect.pure (Eta_http.Server.Response.make ~status:200 ~body ())
  in
  with_h1_connection handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    ("GET /stream-release HTTP/1.1\r\nHost: example.test\r\n"
   ^ "Connection: close\r\n\r\n")
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check string) "response"
    ("HTTP/1.1 200 OK\r\nConnection: close\r\n"
   ^ "Transfer-Encoding: chunked\r\n\r\n"
   ^ "7\r\nchunk-a\r\n7\r\nchunk-b\r\n0\r\n\r\n")
    response;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "released after body written" 1 !released;
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_stream_scope_releases_on_response_completion () =
  (* zio-http HttpApp.test.ts "stream scope" - response stream scope is
     finalized after the response completes. *)
  let released = ref 0 in
  let handler (_request : Eta_http.Server.Request.t) =
    let body =
      stream_body ~length:6
        ~release:(fun () ->
          incr released;
          Eta.Effect.unit)
        [ "stre"; "am" ]
    in
    Eta.Effect.pure (Eta_http.Server.Response.make ~status:200 ~body ())
  in
  with_h1_connection handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    ("GET /stream-scope HTTP/1.1\r\nHost: example.test\r\n"
   ^ "Connection: close\r\n\r\n")
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check string) "response"
    ("HTTP/1.1 200 OK\r\nConnection: close\r\n"
   ^ "Content-Length: 6\r\n\r\nstream")
    response;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "scope released after response completion" 1 !released;
  Alcotest.(check int) "completed requests" 1 stats.completed_requests

let test_h1_server_client_abort_during_response () =
  (* Client disconnect during response: Eta releases the response stream and
     records the already-handled request without synthesizing an HTTP response. *)
  let flow = Eio_mock.Flow.make "eta-http-h1-server-client-abort" in
  Eio_mock.Flow.on_read flow
    [ `Return "GET /abort HTTP/1.1\r\nHost: example.test\r\n\r\n" ];
  Eio_mock.Flow.on_copy_bytes flow
    [
      `Return 4096;
      `Raise (Unix.Unix_error (Unix.EPIPE, "write", ""));
    ];
  let released = ref 0 in
  let handler (_request : Eta_http.Server.Request.t) =
    let body =
      stream_body
        ~release:(fun () ->
          incr released;
          Eta.Effect.unit)
        [ "first"; "second" ]
    in
    Eta.Effect.pure (Eta_http.Server.Response.make ~status:200 ~body ())
  in
  let stats = run_h1_connection_on_flow flow handler in
  Alcotest.(check int) "released on client abort" 1 !released;
  Alcotest.(check int) "completed requests" 1 stats.completed_requests;
  Alcotest.(check bool) "no response emitted after abort" true
    (stats.response_bytes < 10)

let test_h1_server_bad_middleware_responds_with_500 () =
  (* zio-http HttpServer.test.ts "bad middleware responds with 500" - an
     unhandled failure in a wrapper around the handler becomes a 500. *)
  let inner (_request : Eta_http.Server.Request.t) =
    Eta.Effect.pure (Eta_http.Server.Response.text "ok\n")
  in
  let bad_middleware next (request : Eta_http.Server.Request.t) =
    if request.path = "/bad-middleware" then
      failwith "middleware boom"
    else next request
  in
  let handler = bad_middleware inner in
  with_h1_connection handler @@ fun clock flow closed_stats ->
  Eio.Flow.copy_string
    ("GET /bad-middleware HTTP/1.1\r\nHost: example.test\r\n"
   ^ "Connection: close\r\n\r\n")
    flow;
  let response =
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
  in
  Alcotest.(check string) "bad middleware response"
    ("HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\n"
   ^ "Content-Length: 22\r\n\r\ninternal server error\n")
    response;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed requests" 1 stats.completed_requests
