module Loaded = Eta_http

let contains haystack needle =
  let h_len = String.length haystack in
  let n_len = String.length needle in
  let rec loop index =
    index + n_len <= h_len
    && (String.equal needle (String.sub haystack index n_len)
       || loop (index + 1))
  in
  n_len = 0 || loop 0

let test_skeleton_loads () =
  Alcotest.(check bool) "loaded" true true

let test_error_redaction_and_projection () =
  let uri = "https://api.example.test/v1/models?token=secret#frag" in
  let error =
    Eta_http.Error.make ~protocol:H2 ~method_:"GET" ~uri
      (HTTP_status
         {
           status = 503;
           headers =
             [
               ("authorization", "Bearer secret");
               ("Cookie", "sid=secret-cookie");
               ("Set-Cookie", "sid=secret-cookie");
               ("X-API-Key", "secret-key");
               ("Content-Type", "text/plain");
             ];
         })
  in
  Alcotest.(check string)
    "class" "http_status_5xx" (Eta_http.Error.error_class error);
  Alcotest.(check string)
    "retryability" "retryable_if_body_replayable"
    (Eta_http.Error.retryability_to_string (Eta_http.Error.retryability error));
  let pretty = Eta_http.Error.to_string error in
  let json = Eta_http.Error_projection.to_json error in
  List.iter
    (fun output ->
      Alcotest.(check bool) "redacted marker" true
        (contains output "<redacted>");
      Alcotest.(check bool) "auth secret absent" false
        (contains output "Bearer secret");
      Alcotest.(check bool) "cookie secret absent" false
        (contains output "secret-cookie");
      Alcotest.(check bool) "api key absent" false
        (contains output "secret-key");
      Alcotest.(check bool) "query secret absent" false
        (contains output "secret");
      Alcotest.(check bool) "body omitted" true
        (contains output "body"))
    [ pretty; json ]

let test_body_stream_release_once () =
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let released = ref 0 in
  let stream =
    Eta_http.Body.Stream.of_bytes
      ~release:(fun () ->
        incr released;
        Eta.Effect.unit)
      [ Bytes.of_string "abc"; Bytes.of_string "def" ]
  in
  let body =
    Eta.Runtime.run rt (Eta_http.Body.Stream.read_all stream)
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "abcdef" (Bytes.to_string body);
  ignore
    (Eta.Runtime.run rt (Eta_http.Body.Stream.discard stream)
    |> Eta_test.Expect.expect_ok);
  Alcotest.(check int) "release once" 1 !released

let test_url_parse_client_subset () =
  let url =
    Eta_http.Core.Url.of_string
      "https://API.Example.test:8443/v1/models?limit=1#top"
  in
  Alcotest.(check string) "scheme" "https"
    (Eta_http.Core.Url.scheme_to_string (Eta_http.Core.Url.scheme url));
  Alcotest.(check string) "host lowercased" "api.example.test"
    (Eta_http.Core.Url.host url);
  Alcotest.(check (option int)) "port" (Some 8443)
    (Eta_http.Core.Url.port url);
  Alcotest.(check int) "effective port" 8443
    (Eta_http.Core.Url.effective_port url);
  Alcotest.(check string) "path" "/v1/models" (Eta_http.Core.Url.path url);
  Alcotest.(check (option string)) "query" (Some "limit=1")
    (Eta_http.Core.Url.query url);
  Alcotest.(check (option string)) "fragment" (Some "top")
    (Eta_http.Core.Url.fragment url);
  Alcotest.(check string) "origin form" "/v1/models?limit=1"
    (Eta_http.Core.Url.origin_form url);
  Alcotest.(check string) "authority" "api.example.test:8443"
    (Eta_http.Core.Url.authority url)

let test_url_rejects_unsupported_forms () =
  let check_error label expected raw =
    match Eta_http.Core.Url.parse raw with
    | Ok _ -> Alcotest.failf "%s unexpectedly parsed" label
    | Error actual ->
        Alcotest.(check string)
          label expected
          (Eta_http.Core.Url.parse_error_to_string actual)
  in
  check_error "userinfo" "userinfo is not supported"
    "https://user:pass@example.test/";
  check_error "scheme" "unsupported URL scheme \"ftp\""
    "ftp://example.test/";
  check_error "port" "invalid URL port \"99999\""
    "https://example.test:99999/"

let test_h1_writer_get_origin_form () =
  let url =
    Eta_http.Core.Url.of_string
      "https://api.example.test:8443/v1/models?limit=1#frag"
  in
  let request =
    Eta_http.H1.Write.to_string ~method_:"GET" ~url
      ~headers:[ ("Accept", "application/json") ]
      ~body:Empty
  in
  match request with
  | Error error -> Alcotest.fail (Eta_http.Error.to_string error)
  | Ok request ->
      Alcotest.(check string)
        "wire request"
        "GET /v1/models?limit=1 HTTP/1.1\r\n\
         Host: api.example.test:8443\r\n\
         Connection: keep-alive\r\n\
         Accept: application/json\r\n\
         \r\n"
        request

let test_h1_writer_fixed_body () =
  let url = Eta_http.Core.Url.of_string "http://example.test/echo" in
  let request =
    Eta_http.H1.Write.to_string ~method_:"POST" ~url ~headers:[]
      ~body:(Fixed [ Bytes.of_string "abc"; Bytes.of_string "def" ])
  in
  match request with
  | Error error -> Alcotest.fail (Eta_http.Error.to_string error)
  | Ok request ->
      Alcotest.(check string)
        "wire request"
        "POST /echo HTTP/1.1\r\n\
         Host: example.test\r\n\
         Connection: keep-alive\r\n\
         Content-Length: 6\r\n\
         \r\n\
         abcdef"
        request

let test_h1_writer_flow_matches_string_writer () =
  let url = Eta_http.Core.Url.of_string "http://example.test/echo" in
  let body =
    Eta_http.H1.Write.Fixed [ Bytes.of_string "abc"; Bytes.of_string "def" ]
  in
  let expected =
    Eta_http.H1.Write.to_string ~method_:"POST" ~url ~headers:[] ~body
  in
  let buffer = Buffer.create 128 in
  let flow = Eio.Flow.buffer_sink buffer in
  let actual =
    match
      Eta_http.H1.Write.write_to_flow flow ~method_:"POST" ~url ~headers:[]
        ~body
    with
    | Ok () -> Ok (Buffer.contents buffer)
    | Error _ as error -> error
  in
  match (expected, actual) with
  | Ok expected, Ok actual ->
      Alcotest.(check string) "direct flow writer" expected actual
  | Error error, _ | _, Error error -> Alcotest.fail (Eta_http.Error.to_string error)

let test_h1_writer_bytes_matches_string_writer () =
  let url =
    Eta_http.Core.Url.of_string
      "https://API.Example.test:8443/v1/models?limit=1#frag"
  in
  let headers = [ ("Accept", "application/json") ] in
  let body = Eta_http.H1.Write.Empty in
  let expected =
    Eta_http.H1.Write.to_string ~method_:"GET" ~url ~headers ~body
  in
  let bytes = Bytes.create 512 in
  let actual =
    Eta_http.H1.Write.write_to_bytes bytes ~pos:0 ~method_:"GET" ~url
      ~headers ~body
  in
  match (expected, actual) with
  | Ok expected, Ok len ->
      Alcotest.(check string)
        "bytes writer" expected (Bytes.sub_string bytes 0 len)
  | Error error, _ | _, Error error -> Alcotest.fail (Eta_http.Error.to_string error)

let test_h1_writer_bytes_rejects_small_buffer () =
  let url = Eta_http.Core.Url.of_string "http://example.test/echo" in
  let bytes = Bytes.create 8 in
  match
    Eta_http.H1.Write.write_to_bytes bytes ~pos:0 ~method_:"GET" ~url
      ~headers:[] ~body:Eta_http.H1.Write.Empty
  with
  | Ok _ -> Alcotest.fail "small writer buffer unexpectedly succeeded"
  | Error { Eta_http.Error.kind = Header_invalid { reason }; _ } ->
      Alcotest.(check string) "small buffer error" "request buffer too small" reason
  | Error error -> Alcotest.fail (Eta_http.Error.to_string error)

let test_h1_parser_fixed_body () =
  let raw =
    Bytes.of_string
      "HTTP/1.1 200 OK\r\n\
       Content-Type: text/plain\r\n\
       Content-Length: 5\r\n\
       \r\n\
       helloextra"
  in
  match Eta_http.H1.Parse.parse raw ~len:(Bytes.length raw) with
  | Error error ->
      Alcotest.fail (Eta_http.H1.Parse.parse_error_to_string error)
  | Ok response ->
      Alcotest.(check string) "version" "http/1.1"
        (Eta_http.Core.Version.to_string response.version);
      Alcotest.(check int) "status" 200 response.status;
      Alcotest.(check string) "reason" "OK"
        (Eta_http.H1.Parse.span_to_string raw response.reason);
      Alcotest.(check (list (pair string string)))
        "headers"
        [ ("Content-Type", "text/plain"); ("Content-Length", "5") ]
        (Eta_http.H1.Parse.headers_to_list raw response.headers);
      Alcotest.(check string) "body" "hello"
        (Bytes.to_string (Eta_http.H1.Parse.body_to_bytes raw response))

let test_h1_parser_no_body_head () =
  let raw = Bytes.of_string "HTTP/1.0 204 No Content\r\nServer: test\r\n\r\n" in
  match Eta_http.H1.Parse.parse raw ~len:(Bytes.length raw) with
  | Error error ->
      Alcotest.fail (Eta_http.H1.Parse.parse_error_to_string error)
  | Ok response ->
      Alcotest.(check string) "version" "http/1.0"
        (Eta_http.Core.Version.to_string response.version);
      Alcotest.(check int) "status" 204 response.status;
      Alcotest.(check string) "reason" "No Content"
        (Eta_http.H1.Parse.span_to_string raw response.reason);
      Alcotest.(check string) "body" ""
        (Bytes.to_string (Eta_http.H1.Parse.body_to_bytes raw response))

let test_h1_parser_rejects_bad_content_length () =
  let raw =
    Bytes.of_string "HTTP/1.1 200 OK\r\nContent-Length: nope\r\n\r\n"
  in
  match Eta_http.H1.Parse.parse raw ~len:(Bytes.length raw) with
  | Ok _ -> Alcotest.fail "invalid Content-Length unexpectedly parsed"
  | Error error ->
      Alcotest.(check string)
        "error" "invalid Content-Length \"nope\""
        (Eta_http.H1.Parse.parse_error_to_string error)

let test_h1_parser_rejects_conflicting_content_length () =
  let raw =
    Bytes.of_string
      "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello"
  in
  match Eta_http.H1.Parse.parse raw ~len:(Bytes.length raw) with
  | Ok _ -> Alcotest.fail "conflicting Content-Length unexpectedly parsed"
  | Error error ->
      Alcotest.(check string)
        "error" "invalid Content-Length \"6\""
        (Eta_http.H1.Parse.parse_error_to_string error)

let test_transport_resolve_stream_success () =
  let net = Eio_mock.Net.make "eta-http-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 443) in
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  let url = Eta_http.Core.Url.of_string "https://example.test/path" in
  let target = Eta_http.Transport.Connect.target_of_url url in
  Alcotest.(check string) "host" "example.test" target.host;
  Alcotest.(check int) "port" 443 target.port;
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let result =
    Eta_http.Transport.Connect.resolve_stream ~net ~method_:"GET" target
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "one address" 1 (List.length result)

let test_transport_resolve_stream_empty_is_typed () =
  let net = Eio_mock.Net.make "eta-http-net-empty" in
  Eio_mock.Net.on_getaddrinfo net [ `Return [] ];
  let url = Eta_http.Core.Url.of_string "https://missing.example.test/" in
  let target = Eta_http.Transport.Connect.target_of_url url in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  match
    Eta_http.Transport.Connect.resolve_stream ~net ~method_:"GET" target
    |> Eta.Runtime.run rt
  with
  | Eta.Exit.Ok _ -> Alcotest.fail "empty DNS result unexpectedly succeeded"
  | Eta.Exit.Error
      (Eta.Cause.Fail
        { Eta_http.Error.kind = Dns_error { host; message }; _ }) ->
      Alcotest.(check string) "host" "missing.example.test" host;
      Alcotest.(check bool) "message" true
        (contains message "no stream addresses")
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected DNS failure shape: %a"
        (Eta.Cause.pp Eta_http.Error.pp)
        cause

let test_transport_connect_tcp_success () =
  let net = Eio_mock.Net.make "eta-http-net-connect" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 443) in
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return (Eio_mock.Flow.make "eta-http-tcp") ];
  let url = Eta_http.Core.Url.of_string "https://example.test/path" in
  let target = Eta_http.Transport.Connect.target_of_url url in
  Eta_test.with_test_clock @@ fun sw _clock rt ->
  Eta_http.Transport.Connect.connect_tcp ~sw ~net ~method_:"GET" target
  |> Eta.Runtime.run rt
  |> Eta_test.Expect.expect_ok
  |> ignore

let test_transport_connect_tcp_failure_is_typed () =
  let net = Eio_mock.Net.make "eta-http-net-connect-fail" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 443) in
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Raise (Failure "connect boom") ];
  let url = Eta_http.Core.Url.of_string "https://example.test/path" in
  let target = Eta_http.Transport.Connect.target_of_url url in
  Eta_test.with_test_clock @@ fun sw _clock rt ->
  match
    Eta_http.Transport.Connect.connect_tcp ~sw ~net ~method_:"GET" target
    |> Eta.Runtime.run rt
  with
  | Eta.Exit.Ok _ -> Alcotest.fail "TCP connect unexpectedly succeeded"
  | Eta.Exit.Error
      (Eta.Cause.Fail
        { Eta_http.Error.kind = Connect_error { message }; _ }) ->
      Alcotest.(check bool) "message" true (contains message "connect boom")
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected connect failure shape: %a"
        (Eta.Cause.pp Eta_http.Error.pp)
        cause

let test_h1_client_request_on_flow_fixed_response () =
  let flow = Eio_mock.Flow.make "eta-http-h1-flow" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello" ];
  let url = Eta_http.Core.Url.of_string "http://example.test/models" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http.H1.Client.request_on_flow ~flow request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  Alcotest.(check (option string))
    "content-length" (Some "5")
    (Eta_http.Core.Header.get "content-length" response.headers);
  let body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "hello" (Bytes.to_string body)

let test_h1_client_reads_split_response () =
  let flow = Eio_mock.Flow.make "eta-http-h1-split-flow" in
  Eio_mock.Flow.on_read flow
    [
      `Return "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n";
      `Return "\r\nhe";
      `Return "llo";
    ];
  let url = Eta_http.Core.Url.of_string "http://example.test/split" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http.H1.Client.request_on_flow ~flow request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  let body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "hello" (Bytes.to_string body)

let test_h1_client_rejects_chunked_until_s3 () =
  let flow = Eio_mock.Flow.make "eta-http-h1-chunked-flow" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n" ];
  let url = Eta_http.Core.Url.of_string "http://example.test/chunked" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  match
    Eta_http.H1.Client.request_on_flow ~flow request |> Eta.Runtime.run rt
  with
  | Eta.Exit.Ok _ -> Alcotest.fail "chunked response unexpectedly succeeded"
  | Eta.Exit.Error
      (Eta.Cause.Fail
        { Eta_http.Error.kind = Decode_error { codec; message }; _ }) ->
      Alcotest.(check string) "codec" "chunked" codec;
      Alcotest.(check bool) "message" true (contains message "S3")
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected chunked failure shape: %a"
        (Eta.Cause.pp Eta_http.Error.pp)
        cause

let test_h1_client_head_ignores_chunked_body_headers () =
  let flow = Eio_mock.Flow.make "eta-http-h1-head-flow" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ];
  let url = Eta_http.Core.Url.of_string "http://example.test/head" in
  let request : Eta_http.H1.Client.request =
    { method_ = "HEAD"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http.H1.Client.request_on_flow ~flow request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  let body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "empty body" 0 (Bytes.length body)

let test_h1_pool_reuses_healthy_idle_connection () =
  let net = Eio_mock.Net.make "eta-http-h1-pool-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let flow = Eio_mock.Flow.make "eta-http-h1-pool-flow" in
  Eio_mock.Flow.on_read flow
    [
      `Return "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none";
      `Return "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo";
    ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return flow ];
  let health_checks = ref 0 in
  let health_check _flow =
    incr health_checks;
    Eta.Effect.unit
  in
  let authenticator =
    match Ca_certs.authenticator () with
    | Ok authenticator -> authenticator
    | Error (`Msg msg) -> Alcotest.fail msg
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/pool" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  Eta_test.with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http.H1.Client.make_pool ~max_size:1 ~health_check ~sw ~net
      ~authenticator url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let read_once () =
    let response =
      Eta_http.H1.Client.request_with_pool pool request
      |> Eta.Runtime.run rt
      |> Eta_test.Expect.expect_ok
    in
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
    |> Bytes.to_string
  in
  Alcotest.(check string) "first body" "one" (read_once ());
  Alcotest.(check string) "second body" "two" (read_once ());
  let stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "one TCP open" 1 stats.Eta.Pool.opened;
  Alcotest.(check int) "idle" 1 stats.idle;
  Alcotest.(check int) "health check on reuse" 1 !health_checks

let test_h1_pool_rejects_unhealthy_idle_connection () =
  let net = Eio_mock.Net.make "eta-http-h1-pool-unhealthy-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let first_flow = Eio_mock.Flow.make "eta-http-h1-pool-first-flow" in
  let second_flow = Eio_mock.Flow.make "eta-http-h1-pool-second-flow" in
  Eio_mock.Flow.on_read first_flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none" ];
  Eio_mock.Flow.on_read second_flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo" ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ]; `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return first_flow; `Return second_flow ];
  let health_checks = ref 0 in
  let health_check _flow =
    incr health_checks;
    Eta.Effect.fail
      (Eta_http.Error.make ~protocol:H1 ~method_:"*" ~uri:"http://example.test"
         (Connection_closed { during = Pool }))
  in
  let authenticator =
    match Ca_certs.authenticator () with
    | Ok authenticator -> authenticator
    | Error (`Msg msg) -> Alcotest.fail msg
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/pool" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  Eta_test.with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http.H1.Client.make_pool ~max_size:1 ~health_check ~sw ~net
      ~authenticator url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let read_once () =
    let response =
      Eta_http.H1.Client.request_with_pool pool request
      |> Eta.Runtime.run rt
      |> Eta_test.Expect.expect_ok
    in
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
    |> Bytes.to_string
  in
  Alcotest.(check string) "first body" "one" (read_once ());
  Alcotest.(check string) "second body" "two" (read_once ());
  let stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "two TCP opens" 2 stats.Eta.Pool.opened;
  Alcotest.(check int) "one rejected" 1 stats.health_rejected;
  Alcotest.(check int) "one closed" 1 stats.closed;
  Alcotest.(check int) "health check called" 1 !health_checks

let test_h1_pool_holds_checkout_until_body_eof () =
  let net = Eio_mock.Net.make "eta-http-h1-pool-release-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let flow = Eio_mock.Flow.make "eta-http-h1-pool-release-flow" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello" ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return flow ];
  let authenticator =
    match Ca_certs.authenticator () with
    | Ok authenticator -> authenticator
    | Error (`Msg msg) -> Alcotest.fail msg
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/release" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  Eta_test.with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http.H1.Client.make_pool ~max_size:1 ~sw ~net ~authenticator url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let response =
    Eta_http.H1.Client.request_with_pool pool request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let open_stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "active while body open" 1 open_stats.active;
  Alcotest.(check int) "not idle while body open" 0 open_stats.idle;
  let body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "hello" (Bytes.to_string body);
  let closed_stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "released after eof" 0 closed_stats.active;
  Alcotest.(check int) "idle after eof" 1 closed_stats.idle

let test_h1_pool_discard_releases_checkout () =
  let net = Eio_mock.Net.make "eta-http-h1-pool-discard-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let flow = Eio_mock.Flow.make "eta-http-h1-pool-discard-flow" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndrop" ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return flow ];
  let authenticator =
    match Ca_certs.authenticator () with
    | Ok authenticator -> authenticator
    | Error (`Msg msg) -> Alcotest.fail msg
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/discard" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  Eta_test.with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http.H1.Client.make_pool ~max_size:1 ~sw ~net ~authenticator url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let response =
    Eta_http.H1.Client.request_with_pool pool request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let open_stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "active while body open" 1 open_stats.active;
  Alcotest.(check int) "not idle while body open" 0 open_stats.idle;
  Eta_http.Body.Stream.discard response.body
  |> Eta.Runtime.run rt
  |> Eta_test.Expect.expect_ok;
  let closed_stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "released after discard" 0 closed_stats.active;
  Alcotest.(check int) "idle after discard" 1 closed_stats.idle

let test_client_make_h1_request_path () =
  let net = Eio_mock.Net.make "eta-http-client-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let flow = Eio_mock.Flow.make "eta-http-client-flow" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return flow ];
  let authenticator =
    match Ca_certs.authenticator () with
    | Ok authenticator -> authenticator
    | Error (`Msg msg) -> Alcotest.fail msg
  in
  Eta_test.with_test_clock @@ fun sw _clock rt ->
  let client = Eta_http.Client.make_h1 ~sw ~net ~authenticator () in
  let request = Eta_http.Request.make "GET" "http://example.test/models" in
  let response =
    Eta_http.request client request |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  let body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "ok" (Bytes.to_string body)

let same_cipher_set left right =
  List.length left = List.length right
  && List.for_all (fun cipher -> List.mem cipher right) left

let reject_if_dhe cipher =
  match Tls.Ciphersuite.ciphersuite_kex cipher with `FFDHE -> false | _ -> true

let test_tls_chokepoint_policy () =
  let authenticator =
    match Ca_certs.authenticator () with
    | Ok authenticator -> authenticator
    | Error (`Msg msg) -> Alcotest.fail msg
  in
  let client = Eta_http.Tls.Config.default_client ~authenticator () in
  let config = Tls.Config.of_client client in
  Alcotest.(check bool)
    "TLS 1.2 only"
    true
    (config.Tls.Config.protocol_versions = Eta_http.Tls.Config.policy_version);
  Alcotest.(check bool)
    "exact policy ciphers"
    true
    (same_cipher_set config.ciphers Eta_http.Tls.Config.policy_ciphers);
  Alcotest.(check bool)
    "no DHE"
    true
    (List.for_all reject_if_dhe config.ciphers);
  Alcotest.(check int) "no TLS 1.3 ciphers" 0
    (List.length (Tls.Config.ciphers13 config));
  Alcotest.(check (list string))
    "default ALPN" [ "h2"; "http/1.1" ] config.alpn_protocols

let () =
  Alcotest.run "eta-http"
    [
      ("skeleton", [ Alcotest.test_case "loads" `Quick test_skeleton_loads ]);
      ( "error",
        [
          Alcotest.test_case "redaction and projection" `Quick
            test_error_redaction_and_projection;
        ] );
      ( "body",
        [
          Alcotest.test_case "release once" `Quick test_body_stream_release_once;
        ] );
      ( "client",
        [
          Alcotest.test_case "make_h1 request path" `Quick
            test_client_make_h1_request_path;
        ] );
      ( "url",
        [
          Alcotest.test_case "client subset" `Quick test_url_parse_client_subset;
          Alcotest.test_case "reject unsupported forms" `Quick
            test_url_rejects_unsupported_forms;
        ] );
      ( "h1-write",
        [
          Alcotest.test_case "GET origin-form" `Quick
            test_h1_writer_get_origin_form;
          Alcotest.test_case "fixed body" `Quick test_h1_writer_fixed_body;
          Alcotest.test_case "flow matches string writer" `Quick
            test_h1_writer_flow_matches_string_writer;
          Alcotest.test_case "bytes matches string writer" `Quick
            test_h1_writer_bytes_matches_string_writer;
          Alcotest.test_case "bytes rejects small buffer" `Quick
            test_h1_writer_bytes_rejects_small_buffer;
        ] );
      ( "h1-parse",
        [
          Alcotest.test_case "fixed body" `Quick test_h1_parser_fixed_body;
          Alcotest.test_case "no body response" `Quick test_h1_parser_no_body_head;
          Alcotest.test_case "bad content length" `Quick
            test_h1_parser_rejects_bad_content_length;
          Alcotest.test_case "conflicting content length" `Quick
            test_h1_parser_rejects_conflicting_content_length;
        ] );
      ( "h1-client",
        [
          Alcotest.test_case "request on flow fixed response" `Quick
            test_h1_client_request_on_flow_fixed_response;
          Alcotest.test_case "split response" `Quick
            test_h1_client_reads_split_response;
          Alcotest.test_case "reject chunked until S3" `Quick
            test_h1_client_rejects_chunked_until_s3;
          Alcotest.test_case "HEAD ignores chunked body headers" `Quick
            test_h1_client_head_ignores_chunked_body_headers;
          Alcotest.test_case "pool reuses healthy idle connection" `Quick
            test_h1_pool_reuses_healthy_idle_connection;
          Alcotest.test_case "pool rejects unhealthy idle connection" `Quick
            test_h1_pool_rejects_unhealthy_idle_connection;
          Alcotest.test_case "pool holds checkout until body EOF" `Quick
            test_h1_pool_holds_checkout_until_body_eof;
          Alcotest.test_case "pool discard releases checkout" `Quick
            test_h1_pool_discard_releases_checkout;
        ] );
      ( "transport",
        [
          Alcotest.test_case "resolve stream success" `Quick
            test_transport_resolve_stream_success;
          Alcotest.test_case "resolve stream empty typed" `Quick
            test_transport_resolve_stream_empty_is_typed;
          Alcotest.test_case "connect tcp success" `Quick
            test_transport_connect_tcp_success;
          Alcotest.test_case "connect tcp failure typed" `Quick
            test_transport_connect_tcp_failure_is_typed;
        ] );
      ( "tls",
        [
          Alcotest.test_case "chokepoint policy" `Quick
            test_tls_chokepoint_policy;
        ] );
    ]
