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

let with_h1_connection ?(config = Eta_http_eio.Server.Config.default) handler
    client_action =
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

let check_bad_host_rejected ~name wire =
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
    (String.starts_with ~prefix:"HTTP/1.1 400 Bad Request" response);
  Alcotest.(check bool) (name ^ " handler not called") false !handler_called;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) (name ^ " completed requests") 0 stats.completed_requests;
  Alcotest.(check int) (name ^ " protocol errors") 1 stats.protocol_errors

let test_h1_server_connection_rejects_missing_http11_host () =
  check_bad_host_rejected ~name:"missing host"
    "GET /missing HTTP/1.1\r\nConnection: close\r\n\r\n"

let test_h1_server_connection_rejects_duplicate_http11_host () =
  check_bad_host_rejected ~name:"duplicate host"
    ("GET /duplicate HTTP/1.1\r\nHost: example.test\r\n"
   ^ "Host: shadow.test\r\nConnection: close\r\n\r\n")

let test_h1_server_connection_rejects_invalid_http11_host () =
  check_bad_host_rejected ~name:"invalid host"
    "GET /invalid HTTP/1.1\r\nHost: bad/name\r\nConnection: close\r\n\r\n"

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
