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

let test_body_stream_reader_release_once () =
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let released = ref 0 in
  let values =
    ref
      [
        Eta_http.Body.Stream.Chunk (Bytes.of_string "a");
        Eta_http.Body.Stream.Last (Bytes.of_string "b");
      ]
  in
  let stream =
    Eta_http.Body.Stream.of_reader
      ~release:(fun () ->
        incr released;
        Eta.Effect.unit)
      (fun () ->
        match !values with
        | [] -> Eta.Effect.pure Eta_http.Body.Stream.End
        | next :: rest ->
            values := rest;
            Eta.Effect.pure next)
  in
  let body =
    Eta.Runtime.run rt (Eta_http.Body.Stream.read_all stream)
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "ab" (Bytes.to_string body);
  ignore
    (Eta.Runtime.run rt (Eta_http.Body.Stream.discard stream)
    |> Eta_test.Expect.expect_ok);
  Alcotest.(check int) "release once" 1 !released

let chunked_reader_of_string context raw =
  let offset = ref 0 in
  let fail message =
    Eta.Effect.fail
      (Eta_http.Error.make ~protocol:context.Eta_http.Body.Chunked.protocol
         ~method_:context.method_ ~uri:context.uri
         (Decode_error { codec = "chunked-fixture"; message }))
  in
  let read_exact n =
    if n < 0 then invalid_arg "read_exact";
    if !offset + n > String.length raw then fail "fixture EOF"
    else
      let chunk = Bytes.of_string (String.sub raw !offset n) in
      offset := !offset + n;
      Eta.Effect.pure chunk
  in
  let read_line ~limit =
    let rec loop index =
      if index - !offset > limit then fail "line too long"
      else if index + 1 >= String.length raw then fail "line EOF"
      else if
        Char.equal raw.[index] '\r' && Char.equal raw.[index + 1] '\n'
      then
        let line = String.sub raw !offset (index - !offset) in
        offset := index + 2;
        Eta.Effect.pure line
      else loop (index + 1)
    in
    loop !offset
  in
  { Eta_http.Body.Chunked.read_exact; read_line }

let test_chunked_decodes_trailers () =
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let context =
    {
      Eta_http.Body.Chunked.protocol = Eta_http.Error.H1;
      method_ = "GET";
      uri = "http://example.test/chunked";
    }
  in
  let reader =
    chunked_reader_of_string context
      "4\r\nWiki\r\n5;ext=1\r\npedia\r\n0\r\nX-Trailer: ok\r\n\r\n"
  in
  let decoder = Eta_http.Body.Chunked.create ~context ~reader () in
  let body =
    let rec loop acc =
      Eta_http.Body.Chunked.read decoder
      |> Eta.Effect.bind (function
           | None -> Eta.Effect.pure (Bytes.concat Bytes.empty (List.rev acc))
           | Some chunk -> loop (chunk :: acc))
    in
    Eta.Runtime.run rt (loop []) |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "decoded" "Wikipedia" (Bytes.to_string body);
  Alcotest.(check (option string))
    "trailer" (Some "ok")
    (Eta_http.Core.Header.get "x-trailer"
       (Eta_http.Body.Chunked.trailers decoder))

let test_gzip_transducer_roundtrip () =
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let input =
    Eta_http.Body.Stream.of_bytes
      [ Bytes.of_string "alpha"; Bytes.of_string "-beta"; Bytes.of_string "-gamma" ]
  in
  let encoded = Eta_http.Body.Transducer.gzip_encode input in
  let compressed =
    Eta.Runtime.run rt (Eta_http.Body.Stream.read_all encoded)
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check bool) "compressed non-empty" true (Bytes.length compressed > 0);
  let decoded =
    Eta_http.Body.Transducer.gzip_decode
      (Eta_http.Body.Stream.of_bytes [ compressed ])
  in
  let body =
    Eta.Runtime.run rt (Eta_http.Body.Stream.read_all decoded)
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "roundtrip" "alpha-beta-gamma" (Bytes.to_string body)

let test_gzip_transducer_expansion_cap () =
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let input = Eta_http.Body.Stream.of_bytes [ Bytes.make 128 'x' ] in
  let encoded = Eta_http.Body.Transducer.gzip_encode input in
  let compressed =
    Eta.Runtime.run rt (Eta_http.Body.Stream.read_all encoded)
    |> Eta_test.Expect.expect_ok
  in
  let decoded =
    Eta_http.Body.Transducer.gzip_decode ~max_decoded_bytes:32
      (Eta_http.Body.Stream.of_bytes [ compressed ])
  in
  match Eta.Runtime.run rt (Eta_http.Body.Stream.read_all decoded) with
  | Eta.Exit.Ok _ -> Alcotest.fail "gzip expansion cap unexpectedly succeeded"
  | Eta.Exit.Error
      (Eta.Cause.Fail
        { Eta_http.Error.kind = Decode_error { codec; message }; _ }) ->
      Alcotest.(check string) "codec" "gzip" codec;
      Alcotest.(check bool) "message" true (contains message "exceeds")
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected gzip failure shape: %a"
        (Eta.Cause.pp Eta_http.Error.pp)
        cause

let gzip_compress rt value =
  let input = Eta_http.Body.Stream.of_bytes [ Bytes.of_string value ] in
  let encoded = Eta_http.Body.Transducer.gzip_encode input in
  Eta.Runtime.run rt (Eta_http.Body.Stream.read_all encoded)
  |> Eta_test.Expect.expect_ok

let expect_gzip_decode_error rt label bytes =
  let decoded =
    Eta_http.Body.Transducer.gzip_decode
      (Eta_http.Body.Stream.of_bytes [ bytes ])
  in
  match Eta.Runtime.run rt (Eta_http.Body.Stream.read_all decoded) with
  | Eta.Exit.Ok _ -> Alcotest.failf "%s unexpectedly decoded" label
  | Eta.Exit.Error
      (Eta.Cause.Fail
        { Eta_http.Error.kind = Decode_error { codec = "gzip"; _ }; _ }) ->
      ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s unexpected failure shape: %a" label
        (Eta.Cause.pp Eta_http.Error.pp)
        cause

let test_gzip_transducer_rejects_truncated_stream () =
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let compressed = gzip_compress rt "truncated-body" in
  let truncated = Bytes.sub compressed 0 (Bytes.length compressed - 4) in
  expect_gzip_decode_error rt "truncated" truncated

let test_gzip_transducer_rejects_crc_mismatch () =
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let compressed = gzip_compress rt "crc-body" in
  let corrupt = Bytes.copy compressed in
  let crc_offset = Bytes.length corrupt - 8 in
  Bytes.set corrupt crc_offset
    (Char.chr (Char.code (Bytes.get corrupt crc_offset) lxor 0xff));
  expect_gzip_decode_error rt "crc" corrupt

let test_gzip_transducer_decodes_concatenated_members () =
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let first = gzip_compress rt "hello " in
  let second = gzip_compress rt "world" in
  let concatenated = Bytes.cat first second in
  let decoded =
    Eta_http.Body.Transducer.gzip_decode
      (Eta_http.Body.Stream.of_bytes [ concatenated ])
  in
  let body =
    Eta.Runtime.run rt (Eta_http.Body.Stream.read_all decoded)
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "hello world" (Bytes.to_string body)

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

let test_h1_client_decodes_chunked_response () =
  let flow = Eio_mock.Flow.make "eta-http-h1-chunked-flow" in
  Eio_mock.Flow.on_read flow
    [
      `Return
        "HTTP/1.1 200 OK\r\n\
         Transfer-Encoding: chunked\r\n\
         \r\n\
         4\r\n\
         Wiki\r\n\
         5\r\n\
         pedia\r\n\
         0\r\n\
         X-Trailer: ok\r\n\
         \r\n";
    ];
  let url = Eta_http.Core.Url.of_string "http://example.test/chunked" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http.H1.Client.request_on_flow ~flow request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let trailers =
    response.trailers () |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "Wikipedia" (Bytes.to_string body);
  Alcotest.(check (option string))
    "trailer" (Some "ok")
    (Eta_http.Core.Header.get "x-trailer" trailers)

let test_h1_client_streaming_request_body_releases () =
  let flow = Eio_mock.Flow.make "eta-http-h1-stream-request-flow" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" ];
  let released = ref 0 in
  let body =
    Eta_http.Body.Stream.of_bytes
      ~release:(fun () ->
        incr released;
        Eta.Effect.unit)
      [ Bytes.of_string "abc"; Bytes.of_string "def" ]
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/upload" in
  let request : Eta_http.H1.Client.request =
    { method_ = "POST"; url; headers = []; body = Eta_http.H1.Client.Stream body }
  in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http.H1.Client.request_on_flow ~flow request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let response_body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "response" "ok" (Bytes.to_string response_body);
  Alcotest.(check int) "request body released" 1 !released
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

let wait_until label predicate =
  let rec loop attempts =
    if predicate () then ()
    else if attempts = 0 then Alcotest.failf "%s did not become true" label
    else (
      Eta_test.Async.yield ();
      loop (attempts - 1))
  in
  loop 50

let test_h1_pool_request_cancellation_releases_checkout () =
  let net = Eio_mock.Net.make "eta-http-h1-pool-cancel-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let flow = Eio_mock.Flow.make "eta-http-h1-pool-cancel-flow" in
  let never = Eta_test.Async.unresolved () in
  Eio_mock.Flow.on_read flow [ `Await never ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return flow ];
  let authenticator =
    match Ca_certs.authenticator () with
    | Ok authenticator -> authenticator
    | Error (`Msg msg) -> Alcotest.fail msg
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/cancel" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  Eta_test.with_test_clock @@ fun sw clock rt ->
  let pool =
    Eta_http.H1.Client.make_pool ~max_size:1 ~sw ~net ~authenticator url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let timed =
    let timeout_error =
      Eta_http.Error.make ~protocol:H1 ~method_:"GET"
        ~uri:"http://example.test/cancel"
        (Response_header_timeout { timeout_ms = Some 1 })
    in
    Eta_http.H1.Client.request_with_pool pool request
    |> Eta.Effect.timeout_as (Eta.Duration.ms 1) ~on_timeout:timeout_error
  in
  let result = Eta_test.Async.fork_run sw rt timed in
  wait_until "request active" (fun () ->
      (Eta_http.H1.Client.pool_stats pool).active = 1);
  Eta_test.Test_clock.adjust clock (Eta.Duration.ms 1);
  (match Eta_test.Async.await result with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        { Eta_http.Error.kind = Response_header_timeout { timeout_ms = Some 1 }; _ }) ->
      ()
  | Eta.Exit.Ok _ -> Alcotest.fail "cancelled request unexpectedly succeeded"
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected cancellation result: %a"
        (Eta.Cause.pp Eta_http.Error.pp)
        cause);
  wait_until "request checkout released" (fun () ->
      (Eta_http.H1.Client.pool_stats pool).active = 0);
  let stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "active released" 0 stats.active

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

let retry_response ?(headers = []) ?(release = fun () -> Eta.Effect.unit) status =
  Eta_http.Response.make ~status ~headers
    ~body:(Eta_http.Body.Stream.of_bytes ~release [])
    ()

let retry_client responses =
  let attempts = ref 0 in
  let request _ =
    let index = min !attempts (Array.length responses - 1) in
    incr attempts;
    Eta.Effect.pure (responses.(index) ())
  in
  ( attempts,
    Eta_http.Client.make_for_test ~protocol:Eta_http.Client.H1 ~request
      ~stats:(fun () ->
        Eta.Effect.pure
          {
            Eta_http.Client.protocol = H1;
            active = 0;
            idle = 0;
            capacity = 0;
            opened = !attempts;
            released = 0;
          })
      ~shutdown:(fun () -> Eta.Effect.unit) )

let test_idempotency_classifier () =
  let get =
    Eta_http.Request.make ~body:(Fixed [ Bytes.of_string "x" ]) "GET"
      "https://api.example.test/resource"
  in
  Alcotest.(check bool) "GET retryable" true
    (Eta_http.Idempotency.retryable get);
  let post =
    Eta_http.Request.make ~body:(Fixed [ Bytes.of_string "x" ]) "POST"
      "https://api.example.test/resource"
  in
  Alcotest.(check bool) "POST default" false
    (Eta_http.Idempotency.retryable post);
  let post_with_key = Eta_http.Idempotency.with_idempotency_key "k1" post in
  Alcotest.(check bool) "POST with key" true
    (Eta_http.Idempotency.retryable post_with_key);
  let one_shot =
    Eta_http.Request.make
      ~body:(Stream (Eta_http.Body.Stream.of_bytes [ Bytes.of_string "x" ]))
      "GET" "https://api.example.test/resource"
  in
  Alcotest.(check bool) "one-shot body" false
    (Eta_http.Idempotency.retryable one_shot)

let test_retry_after_parser () =
  let seconds =
    Eta_http.Retry_policy.retry_after "5" |> Option.map Eta.Duration.to_ms
  in
  Alcotest.(check (option int)) "delta seconds" (Some 5000) seconds;
  let http_date =
    Eta_http.Retry_policy.retry_after ~now_s:1445412475.0
      "Wed, 21 Oct 2015 07:28:00 GMT"
    |> Option.map Eta.Duration.to_ms
  in
  Alcotest.(check (option int)) "http date" (Some 5000) http_date

let test_retry_policy_schedule_backoff () =
  let policy =
    Eta_http.Retry_policy.make ~max_attempts:2
      ~schedule:(Eta.Schedule.spaced (Eta.Duration.ms 7))
      ~respect_retry_after:false ()
  in
  let request =
    Eta_http.Request.make "GET" "https://api.example.test/retry"
  in
  let response = retry_response 503 in
  match
    Eta_http.Retry_policy.classify_response policy ~request ~attempt:1 response
  with
  | Retry_after delay ->
      Alcotest.(check int) "delay" 7 (Eta.Duration.to_ms delay)
  | Retry_with_new_connection _ -> Alcotest.fail "unexpected new connection"
  | Stop -> Alcotest.fail "retry stopped"

let test_retry_succeeds_on_third_attempt () =
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let released = ref 0 in
  let attempts, client =
    retry_client
      [|
        (fun () ->
          retry_response ~headers:[ "Retry-After", "0" ]
            ~release:(fun () ->
              incr released;
              Eta.Effect.unit)
            503);
        (fun () ->
          retry_response ~headers:[ "Retry-After", "0" ]
            ~release:(fun () ->
              incr released;
              Eta.Effect.unit)
            503);
        (fun () -> retry_response 200);
      |]
  in
  let request = Eta_http.Request.make "GET" "https://api.example.test/retry" in
  let response =
    Eta.Runtime.run rt (Eta_http.request_with_retry client request)
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  Alcotest.(check int) "attempts" 3 !attempts;
  Alcotest.(check int) "discard failed bodies" 2 !released

let test_retry_non_idempotent_requires_opt_in () =
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let post =
    Eta_http.Request.make ~body:(Fixed [ Bytes.of_string "payload" ]) "POST"
      "https://api.example.test/retry"
  in
  let attempts, client =
    retry_client
      [|
        (fun () -> retry_response ~headers:[ "Retry-After", "0" ] 503);
        (fun () -> retry_response 200);
      |]
  in
  let response =
    Eta.Runtime.run rt (Eta_http.request_with_retry client post)
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "default status" 503 response.status;
  Alcotest.(check int) "default attempts" 1 !attempts;
  let attempts, client =
    retry_client
      [|
        (fun () -> retry_response ~headers:[ "Retry-After", "0" ] 503);
        (fun () -> retry_response 200);
      |]
  in
  let response =
    Eta.Runtime.run rt
      (Eta_http.request_with_retry client
         (Eta_http.Idempotency.with_idempotency_key "key-1" post))
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "key status" 200 response.status;
  Alcotest.(check int) "key attempts" 2 !attempts

let test_retry_always_still_requires_replayable_body () =
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let attempts, client =
    retry_client
      [|
        (fun () -> retry_response ~headers:[ "Retry-After", "0" ] 503);
        (fun () -> retry_response 200);
      |]
  in
  let request =
    Eta_http.Request.make
      ~body:(Stream (Eta_http.Body.Stream.of_bytes [ Bytes.of_string "x" ]))
      "POST" "https://api.example.test/retry"
  in
  let policy =
    Eta_http.Retry_policy.always ~max_attempts:3
      ~schedule:(Eta.Schedule.spaced Eta.Duration.zero)
      ()
  in
  let response =
    Eta.Runtime.run rt (Eta_http.request_with_retry ~policy client request)
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 503 response.status;
  Alcotest.(check int) "attempts" 1 !attempts

let span_attr key span = List.assoc_opt key span.Eta.Tracer.attrs

let find_span name tracer =
  match List.filter (fun span -> String.equal span.Eta.Tracer.name name) (Eta.Tracer.dump tracer) with
  | span :: _ -> span
  | [] -> Alcotest.failf "missing span %s" name

let observability_client ?(protocol = Eta_http.Client.H1) request =
  Eta_http.Client.make_for_test ~protocol ~request
    ~stats:(fun () ->
      Eta.Effect.pure
        {
          Eta_http.Client.protocol;
          active = 2;
          idle = 3;
          capacity = 5;
          opened = 8;
          released = 6;
        })
    ~shutdown:(fun () -> Eta.Effect.unit)

let test_observability_success_get_semconv () =
  Eta_test.with_traced_test_clock @@ fun _sw _clock rt tracer ->
  let client =
    observability_client (fun _ -> Eta.Effect.pure (retry_response 200))
  in
  let request = Eta_http.Request.make "GET" "https://api.example.test:8443/a?b=c" in
  let response =
    Eta.Runtime.run rt (Eta_http.Observability.Tracer.request client request)
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  let span = find_span "HTTP GET" tracer in
  Alcotest.(check (option string)) "method" (Some "GET")
    (span_attr "http.request.method" span);
  Alcotest.(check (option string)) "url"
    (Some "https://api.example.test:8443/a?b=c")
    (span_attr "url.full" span);
  Alcotest.(check (option string)) "server" (Some "api.example.test")
    (span_attr "server.address" span);
  Alcotest.(check (option string)) "port" (Some "8443")
    (span_attr "server.port" span);
  Alcotest.(check (option string)) "protocol" (Some "1.1")
    (span_attr "network.protocol.version" span);
  Alcotest.(check (option string)) "status attr" (Some "200")
    (span_attr "http.response.status_code" span)

let test_observability_dns_error_semconv () =
  Eta_test.with_traced_test_clock @@ fun _sw _clock rt tracer ->
  let error =
    Eta_http.Error.make ~method_:"GET" ~uri:"https://missing.example.test/"
      (Dns_error { host = "missing.example.test"; message = "no such host" })
  in
  let client = observability_client (fun _ -> Eta.Effect.fail error) in
  let request = Eta_http.Request.make "GET" "https://missing.example.test/" in
  Eta_test.Expect.expect_typed_failure
    (Eta.Runtime.run rt (Eta_http.Observability.Tracer.request client request))
    (fun err ->
      match err.Eta_http.Error.kind with Dns_error _ -> true | _ -> false);
  let span = find_span "HTTP GET" tracer in
  Alcotest.(check (option string)) "error type" (Some "dns_error")
    (span_attr "error.type" span)

let test_observability_tls_error_semconv () =
  Eta_test.with_traced_test_clock @@ fun _sw _clock rt tracer ->
  let error =
    Eta_http.Error.make ~method_:"GET" ~uri:"https://expired.example.test/"
      (Tls_handshake_error
         { stage = Tls_handshake; message = "certificate expired" })
  in
  let client = observability_client (fun _ -> Eta.Effect.fail error) in
  let request = Eta_http.Request.make "GET" "https://expired.example.test/" in
  Eta_test.Expect.expect_typed_failure
    (Eta.Runtime.run rt (Eta_http.Observability.Tracer.request client request))
    (fun err ->
      match err.Eta_http.Error.kind with
      | Tls_handshake_error _ -> true
      | _ -> false);
  let span = find_span "HTTP GET" tracer in
  Alcotest.(check (option string)) "error type" (Some "tls_handshake_error")
    (span_attr "error.type" span)

let test_observability_retry_success_spans () =
  Eta_test.with_traced_test_clock @@ fun _sw _clock rt tracer ->
  let attempts, client =
    retry_client
      [|
        (fun () -> retry_response ~headers:[ "Retry-After", "0" ] 503);
        (fun () -> retry_response 200);
      |]
  in
  let request = Eta_http.Request.make "GET" "https://api.example.test/retry" in
  let response =
    Eta.Runtime.run rt
      (Eta_http.Observability.Tracer.request_with_retry client request)
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  Alcotest.(check int) "attempts" 2 !attempts;
  let spans = Eta.Tracer.dump tracer in
  Alcotest.(check bool) "parent span" true
    (List.exists (fun span -> String.equal span.Eta.Tracer.name "HTTP GET retry") spans);
  Alcotest.(check bool) "attempt span" true
    (List.exists
       (fun span ->
         String.equal span.Eta.Tracer.name "HTTP GET"
         && Option.equal String.equal
              (span_attr "http.request.resend_count" span)
              (Some "1"))
       spans)

let test_observability_redirect_semconv () =
  let attrs =
    Eta_http.Observability.Semconv.redirect_attrs
      ~location:"https://api.example.test/next"
  in
  Alcotest.(check (option string)) "location"
    (Some "https://api.example.test/next")
    (List.assoc_opt "http.response.header.location" attrs)

let test_observability_h2_protocol_attrs () =
  Eta_test.with_traced_test_clock @@ fun _sw _clock rt tracer ->
  let client =
    observability_client ~protocol:Eta_http.Client.H2 (fun _ ->
        Eta.Effect.pure (retry_response 200))
  in
  let request = Eta_http.Request.make "GET" "https://api.example.test/h2" in
  ignore
    (Eta.Runtime.run rt
       (Eta_http.Observability.Tracer.request ~protocol:Eta_http.Client.H2 client
          request)
    |> Eta_test.Expect.expect_ok);
  let span = find_span "HTTP GET" tracer in
  Alcotest.(check (option string)) "h2" (Some "2")
    (span_attr "network.protocol.version" span)

let test_observability_recursion_disabled () =
  Eta_test.with_traced_test_clock @@ fun _sw _clock rt tracer ->
  let client =
    observability_client (fun _ -> Eta.Effect.pure (retry_response 200))
  in
  let request = Eta_http.Request.make "POST" "https://collector.example.test/v1/traces" in
  ignore
    (Eta.Runtime.run rt
       (Eta_http.Observability.Tracer.request ~enabled:false client request)
    |> Eta_test.Expect.expect_ok);
  Alcotest.(check int) "spans" 0 (List.length (Eta.Tracer.dump tracer))

let test_observability_pool_stats_meter () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let meter = Eta.Meter.in_memory () in
  let rt =
    Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~meter:(Eta.Meter.as_capability meter) ()
  in
  let client =
    observability_client (fun _ -> Eta.Effect.pure (retry_response 200))
  in
  Eta.Runtime.run rt (Eta_http.Observability.Meter.record_client_stats client)
  |> Eta_test.Expect.expect_ok;
  let names = List.map (fun point -> point.Eta.Meter.name) (Eta.Meter.dump meter) in
  Alcotest.(check bool) "active metric" true
    (List.mem "eta_http.client.connections.active" names)

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

let h2_permit label = function
  | Ok permit -> permit
  | Error () -> Alcotest.failf "%s rejected unexpectedly" label

let test_h2_admission_counts_cancelled_until_release () =
  let admission = Eta_http.H2.Admission.create ~max_concurrent:2 in
  let first = h2_permit "first" (Eta_http.H2.Admission.try_acquire admission) in
  let second = h2_permit "second" (Eta_http.H2.Admission.try_acquire admission) in
  Alcotest.(check int) "first stream id" 1
    (Eta_http.H2.Admission.stream_id first);
  Alcotest.(check int) "second stream id" 3
    (Eta_http.H2.Admission.stream_id second);
  (match Eta_http.H2.Admission.try_acquire admission with
  | Ok _ -> Alcotest.fail "third stream should be rejected at limit"
  | Error () -> ());
  Eta_http.H2.Admission.mark_remote_reset admission first;
  let reset_stats = Eta_http.H2.Admission.stats admission in
  Alcotest.(check int) "active after remote reset" 1 reset_stats.active;
  Alcotest.(check int) "cancelled after remote reset" 1 reset_stats.cancelled;
  Alcotest.(check int) "cancelled counts as inflight" 2 reset_stats.inflight;
  (match Eta_http.H2.Admission.try_acquire admission with
  | Ok _ -> Alcotest.fail "cancelled stream should still occupy admission"
  | Error () -> ());
  Alcotest.(check bool) "remote reset release does not queue RST" true
    (Eta_http.H2.Admission.release admission first = Eta_http.H2.Admission.No_rst);
  let third = h2_permit "third" (Eta_http.H2.Admission.try_acquire admission) in
  Alcotest.(check int) "third stream id" 5
    (Eta_http.H2.Admission.stream_id third);
  Alcotest.(check bool) "active release queues RST" true
    (Eta_http.H2.Admission.release admission second = Eta_http.H2.Admission.Queue_rst);
  Alcotest.(check bool) "release is idempotent" true
    (Eta_http.H2.Admission.release admission second = Eta_http.H2.Admission.No_rst);
  Alcotest.(check bool) "third active release queues RST" true
    (Eta_http.H2.Admission.release admission third = Eta_http.H2.Admission.Queue_rst);
  let stats = Eta_http.H2.Admission.stats admission in
  Alcotest.(check int) "active final" 0 stats.active;
  Alcotest.(check int) "cancelled final" 0 stats.cancelled;
  Alcotest.(check int) "opened" 3 stats.opened;
  Alcotest.(check int) "completed" 3 stats.completed;
  Alcotest.(check int) "local resets" 2 stats.local_resets;
  Alcotest.(check int) "remote resets" 1 stats.remote_resets;
  Alcotest.(check int) "rejected" 2 stats.admission_rejected;
  Alcotest.(check int) "max inflight" 2 stats.max_inflight

let h2_stream label = function
  | Ok stream -> stream
  | Error () -> Alcotest.failf "%s rejected unexpectedly" label

let test_h2_stream_state_release_decisions () =
  let state = Eta_http.H2.Stream_state.create ~max_concurrent:2 in
  let first =
    h2_stream "first" (Eta_http.H2.Stream_state.open_stream state ~tag:11)
  in
  let second =
    h2_stream "second" (Eta_http.H2.Stream_state.open_stream state ~tag:12)
  in
  Alcotest.(check int) "first stream id" 1
    (Eta_http.H2.Stream_state.id first);
  Alcotest.(check int) "second stream id" 3
    (Eta_http.H2.Stream_state.id second);
  Alcotest.(check int) "tag" 11 (Eta_http.H2.Stream_state.tag first);
  (match Eta_http.H2.Stream_state.open_stream state ~tag:13 with
  | Ok _ -> Alcotest.fail "third stream should be rejected at limit"
  | Error () -> ());
  Eta_http.H2.Stream_state.mark_remote_reset state
    (Eta_http.H2.Stream_state.id first);
  Alcotest.(check bool) "first remote reset" true
    (Eta_http.H2.Stream_state.status first
    = Eta_http.H2.Stream_state.Remote_reset);
  let reset_stats = Eta_http.H2.Stream_state.stats state in
  Alcotest.(check int) "active after reset" 1 reset_stats.active;
  Alcotest.(check int) "cancelled after reset" 1 reset_stats.cancelled;
  Alcotest.(check int) "cancelled still inflight" 2 reset_stats.inflight;
  Alcotest.(check int) "live after reset" 2 reset_stats.live;
  (match Eta_http.H2.Stream_state.open_stream state ~tag:14 with
  | Ok _ -> Alcotest.fail "cancelled stream should still occupy admission"
  | Error () -> ());
  Alcotest.(check bool) "remote reset release does not queue RST" true
    (Eta_http.H2.Stream_state.release state first
    = Eta_http.H2.Stream_state.No_rst);
  Alcotest.(check bool) "release idempotent" true
    (Eta_http.H2.Stream_state.release state first
    = Eta_http.H2.Stream_state.No_rst);
  let third =
    h2_stream "third" (Eta_http.H2.Stream_state.open_stream state ~tag:13)
  in
  Alcotest.(check int) "third stream id" 5
    (Eta_http.H2.Stream_state.id third);
  Eta_http.H2.Stream_state.mark_complete state second;
  Alcotest.(check bool) "second complete" true
    (Eta_http.H2.Stream_state.status second = Eta_http.H2.Stream_state.Complete);
  Alcotest.(check bool) "complete release does not queue RST" true
    (Eta_http.H2.Stream_state.release state second
    = Eta_http.H2.Stream_state.No_rst);
  Alcotest.(check bool) "active release queues RST" true
    (Eta_http.H2.Stream_state.release state third
    = Eta_http.H2.Stream_state.Queue_rst);
  let stats = Eta_http.H2.Stream_state.stats state in
  Alcotest.(check int) "active final" 0 stats.active;
  Alcotest.(check int) "cancelled final" 0 stats.cancelled;
  Alcotest.(check int) "live final" 0 stats.live;
  Alcotest.(check int) "opened" 3 stats.opened;
  Alcotest.(check int) "completed" 3 stats.completed;
  Alcotest.(check int) "local resets" 1 stats.local_resets;
  Alcotest.(check int) "remote resets" 1 stats.remote_resets;
  Alcotest.(check int) "rejected" 2 stats.admission_rejected;
  Alcotest.(check int) "max inflight" 2 stats.max_inflight

let test_h2_stream_state_close_releases_live_state () =
  let state = Eta_http.H2.Stream_state.create ~max_concurrent:2 in
  let first =
    h2_stream "first" (Eta_http.H2.Stream_state.open_stream state ~tag:1)
  in
  let second =
    h2_stream "second" (Eta_http.H2.Stream_state.open_stream state ~tag:2)
  in
  Eta_http.H2.Stream_state.mark_remote_reset state
    (Eta_http.H2.Stream_state.id first);
  Eta_http.H2.Stream_state.close state;
  Alcotest.(check bool) "first released" true
    (Eta_http.H2.Stream_state.status first = Eta_http.H2.Stream_state.Released);
  Alcotest.(check bool) "second released" true
    (Eta_http.H2.Stream_state.status second = Eta_http.H2.Stream_state.Released);
  (match Eta_http.H2.Stream_state.open_stream state ~tag:3 with
  | Ok _ -> Alcotest.fail "closed state should reject new streams"
  | Error () -> ());
  let stats = Eta_http.H2.Stream_state.stats state in
  Alcotest.(check int) "active closed" 0 stats.active;
  Alcotest.(check int) "cancelled closed" 0 stats.cancelled;
  Alcotest.(check int) "live closed" 0 stats.live

let test_h2_writer_preserves_iovec_slices () =
  let buffer = Bigstringaf.of_string ~off:0 ~len:10 "0123456789" in
  let iovecs = [ { H2.IOVec.buffer; off = 2; len = 4 } ] in
  match Eta_http.H2.Writer.cstructs_of_iovecs iovecs with
  | [ slice ] ->
      Alcotest.(check int) "slice len" 4 (Cstruct.length slice);
      Alcotest.(check string) "slice bytes" "2345" (Cstruct.to_string slice)
  | _ -> Alcotest.fail "expected one cstruct slice"

let test_h2_writer_drains_client_preface_and_request () =
  let client =
    H2.Client_connection.create
      ~error_handler:(fun _ -> Alcotest.fail "unexpected client h2 error")
      ()
  in
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
      `GET "/writer"
  in
  let request_body =
    H2.Client_connection.request client request
      ~error_handler:(fun _ -> Alcotest.fail "unexpected stream h2 error")
      ~response_handler:(fun _ _ -> ())
  in
  H2.Body.Writer.close request_body;
  let buffer = Buffer.create 256 in
  let flow = Eio.Flow.buffer_sink buffer in
  (match Eta_http.H2.Writer.drain_client ~flow client with
  | Yield { written } ->
      Alcotest.(check bool) "wrote bytes" true (written > 24)
  | Close { code; _ } -> Alcotest.failf "unexpected close code=%d" code);
  let output = Buffer.contents buffer in
  let preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" in
  Alcotest.(check string) "connection preface" preface
    (String.sub output 0 (String.length preface));
  match Eta_http.H2.Writer.drain_client ~flow client with
  | Yield { written = 0 } -> ()
  | Yield { written } -> Alcotest.failf "unexpected extra write=%d" written
  | Close { code; _ } -> Alcotest.failf "unexpected second close code=%d" code

let test_h2_writer_blocked_write_teardown () =
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let client =
    H2.Client_connection.create
      ~error_handler:(fun _ -> Alcotest.fail "unexpected client h2 error")
      ()
  in
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
      `GET "/blocked-writer"
  in
  let request_body =
    H2.Client_connection.request client request
      ~error_handler:(fun _ -> Alcotest.fail "unexpected stream h2 error")
      ~response_handler:(fun _ _ -> ())
  in
  H2.Body.Writer.close request_body;
  let started = Eta.Channel.create ~capacity:1 () in
  let blocked = Eta.Channel.create ~capacity:1 () in
  let write_started = ref false in
  let write _iovecs =
    let signal =
      if !write_started then Eta.Effect.unit
      else (
        write_started := true;
        Eta.Channel.try_send started () |> Eta.Effect.map (fun _ -> ()))
    in
    signal
    |> Eta.Effect.bind (fun () ->
           Eta.Channel.recv blocked |> Eta.Effect.map (fun () -> 1))
  in
  let effect =
    Eta.Supervisor.scoped
      {
        run =
          (fun supervisor ->
            let open Eta.Supervisor.Scope in
            let* _writer =
              start supervisor
                (lift (Eta_http.H2.Writer.run_client ~write client))
            in
            let* _ = lift (Eta.Channel.recv started) in
            pure ());
      }
  in
  (match Eta.Runtime.run rt effect with
  | Eta.Exit.Ok () -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "blocked writer scope failed: %a"
        (Eta.Cause.pp (fun fmt `Closed -> Format.pp_print_string fmt "closed"))
        cause);
  Alcotest.(check bool) "write started" true !write_started

let h2_iovecs_to_string iovecs =
  iovecs
  |> Eta_http.H2.Writer.cstructs_of_iovecs
  |> List.map Cstruct.to_string
  |> String.concat ""

let h2_feed_client client data =
  let rec loop off =
    if off < String.length data then (
      let len = String.length data - off in
      let buffer = Bigstringaf.of_string ~off ~len data in
      let consumed = H2.Client_connection.read client buffer ~off:0 ~len in
      if consumed <= 0 then Alcotest.fail "client consumed no h2 bytes";
      loop (off + consumed))
  in
  loop 0

let h2_feed_server server data =
  let rec loop off =
    if off < String.length data then (
      let len = String.length data - off in
      let buffer = Bigstringaf.of_string ~off ~len data in
      let consumed = H2.Server_connection.read server buffer ~off:0 ~len in
      if consumed <= 0 then Alcotest.fail "server consumed no h2 bytes";
      loop (off + consumed))
  in
  loop 0

let rec h2_drain_server_output server acc =
  match H2.Server_connection.next_write_operation server with
  | `Write iovecs ->
      let data = h2_iovecs_to_string iovecs in
      H2.Server_connection.report_write_result server (`Ok (String.length data));
      h2_drain_server_output server (data :: acc)
  | `Yield -> String.concat "" (List.rev acc)
  | `Close _ ->
      H2.Server_connection.report_write_result server `Closed;
      String.concat "" (List.rev acc)

let h2_drain_client_to_server client server =
  match H2.Client_connection.next_write_operation client with
  | `Write iovecs ->
      let data = h2_iovecs_to_string iovecs in
      H2.Client_connection.report_write_result client (`Ok (String.length data));
      h2_feed_server server data;
      true
  | `Yield -> false
  | `Close _ ->
      H2.Client_connection.report_write_result client `Closed;
      false

let h2_drain_server_to_client server client =
  match H2.Server_connection.next_write_operation server with
  | `Write iovecs ->
      let data = h2_iovecs_to_string iovecs in
      H2.Server_connection.report_write_result server (`Ok (String.length data));
      h2_feed_client client data;
      true
  | `Yield -> false
  | `Close _ ->
      H2.Server_connection.report_write_result server `Closed;
      false

let h2_pump_pair ?(limit = 10_000) client server =
  let rec loop remaining =
    if remaining <= 0 then Alcotest.fail "h2 pump did not quiesce"
    else
      let client_progress = h2_drain_client_to_server client server in
      let server_progress = h2_drain_server_to_client server client in
      if client_progress || server_progress then loop (remaining - 1)
  in
  loop limit

let h2_cstruct_chunks ~chunk_size data =
  let rec loop off acc =
    if off >= String.length data then List.rev acc
    else
      let len = min chunk_size (String.length data - off) in
      let buffer = Bigstringaf.of_string ~off ~len data in
      loop (off + len) (Cstruct.of_bigarray buffer :: acc)
  in
  loop 0 []

type h2_read_result = {
  mutable status : int option;
  body : Buffer.t;
  mutable eof : bool;
  mutable client_errors : int;
  mutable stream_errors : int;
}

let h2_read_result () =
  {
    status = None;
    body = Buffer.create 32;
    eof = false;
    client_errors = 0;
    stream_errors = 0;
  }

let h2_schedule_body result body =
  let rec loop () =
    H2.Body.Reader.schedule_read body
      ~on_eof:(fun () -> result.eof <- true)
      ~on_read:(fun bs ~off ~len ->
        Buffer.add_string result.body (Bigstringaf.substring bs ~off ~len);
        loop ())
  in
  loop ()

let h2_pp_client_error = function
  | `Malformed_response msg -> "malformed_response:" ^ msg
  | `Invalid_response_body_length _ -> "invalid_response_body_length"
  | `Protocol_error (code, msg) ->
      Format.asprintf "protocol_error:%a:%s" H2.Error_code.pp_hum code msg
  | `Exn exn -> "exn:" ^ Printexc.to_string exn

type h2_mux_result = {
  mutable mux_status : int option;
  mux_body : Buffer.t;
  mutable mux_eof : bool;
  mutable mux_stream_errors : string list;
  mutable mux_client_errors : string list;
  mutable mux_stream : Eta_http.H2.Multiplexer.stream option;
  mutable mux_release : Eta_http.H2.Stream_state.release option;
}

let h2_mux_result () =
  {
    mux_status = None;
    mux_body = Buffer.create 128;
    mux_eof = false;
    mux_stream_errors = [];
    mux_client_errors = [];
    mux_stream = None;
    mux_release = None;
  }

let h2_mux_create ?max_concurrent ?config result () =
  Eta_http.H2.Multiplexer.create ?max_concurrent ?config
    ~error_handler:(fun error ->
      result.mux_client_errors <- h2_pp_client_error error :: result.mux_client_errors)
    ()

let h2_schedule_mux_body mux result stream body =
  let rec loop () =
    H2.Body.Reader.schedule_read body
      ~on_eof:(fun () ->
        Eta_http.H2.Multiplexer.mark_complete mux stream;
        result.mux_eof <- true)
      ~on_read:(fun bs ~off ~len ->
        Buffer.add_string result.mux_body (Bigstringaf.substring bs ~off ~len);
        loop ())
  in
  loop ()

let h2_open_mux_request ?(meth = `GET) ?body ?(target = "/") ?(tag = 0) mux
    result =
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
      meth target
  in
  match
    Eta_http.H2.Multiplexer.request mux ~tag request
      ~error_handler:(fun stream error ->
        result.mux_stream <- Some stream;
        result.mux_stream_errors <-
          h2_pp_client_error error :: result.mux_stream_errors)
      ~response_handler:(fun stream response response_body ->
        result.mux_stream <- Some stream;
        result.mux_status <- Some (H2.Status.to_code response.status);
        h2_schedule_mux_body mux result stream response_body)
  with
  | Error Eta_http.H2.Multiplexer.Admission_rejected -> Error `Admission_rejected
  | Error Eta_http.H2.Multiplexer.Connection_closed -> Error `Connection_closed
  | Ok opened ->
      result.mux_stream <- Some opened.stream;
      (match body with
      | None -> ()
      | Some body -> H2.Body.Writer.write_string opened.request_body body);
      H2.Body.Writer.close opened.request_body;
      Ok opened

let h2_server_read_body reqd ~on_done =
  let body = H2.Reqd.request_body reqd in
  let buffer = Buffer.create 4096 in
  let rec loop () =
    H2.Body.Reader.schedule_read body
      ~on_eof:(fun () -> on_done (Buffer.contents buffer))
      ~on_read:(fun bs ~off ~len ->
        Buffer.add_string buffer (Bigstringaf.substring bs ~off ~len);
        loop ())
  in
  loop ()

let test_h2_multiplexer_reads_server_response () =
  let result = h2_read_result () in
  let server =
    H2.Server_connection.create
      ~error_handler:(fun ?request:_ _ respond ->
        result.stream_errors <- result.stream_errors + 1;
        let body = respond H2.Headers.empty in
        H2.Body.Writer.close body)
      (fun reqd ->
        H2.Reqd.respond_with_string reqd (H2.Response.create `OK) "hello-read")
  in
  let client =
    H2.Client_connection.create
      ~error_handler:(fun _ -> result.client_errors <- result.client_errors + 1)
      ()
  in
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
      `GET "/reader"
  in
  let request_body =
    H2.Client_connection.request client request
      ~error_handler:(fun _ -> result.stream_errors <- result.stream_errors + 1)
      ~response_handler:(fun response body ->
        result.status <- Some (H2.Status.to_code response.status);
        h2_schedule_body result body)
  in
  H2.Body.Writer.close request_body;
  let request_bytes = Buffer.create 256 in
  let request_flow = Eio.Flow.buffer_sink request_bytes in
  (match Eta_http.H2.Writer.drain_client ~flow:request_flow client with
  | Yield _ -> ()
  | Close { code; _ } -> Alcotest.failf "unexpected client writer close=%d" code);
  h2_feed_server server (Buffer.contents request_bytes);
  let response_bytes = h2_drain_server_output server [] in
  let source =
    Eio.Flow.cstruct_source (h2_cstruct_chunks ~chunk_size:7 response_bytes)
  in
  let reader = Eta_http.H2.Multiplexer.create_client_reader ~buffer_size:128 client in
  let rec loop reads =
    if reads > 100 then Alcotest.fail "h2 reader did not deliver response"
    else if result.eof then ()
    else
      match Eta_http.H2.Multiplexer.read_client_once ~flow:source reader with
      | Read _ -> loop (reads + 1)
      | Eof _ -> loop (reads + 1)
      | Security_error kind ->
          Alcotest.failf "unexpected h2 security error: %s"
            (Eta_http.Error.kind_name kind)
      | Close -> Alcotest.fail "client reader closed before response EOF"
  in
  loop 0;
  Alcotest.(check (option int)) "status" (Some 200) result.status;
  Alcotest.(check string) "body" "hello-read" (Buffer.contents result.body);
  Alcotest.(check int) "client errors" 0 result.client_errors;
  Alcotest.(check int) "stream errors" 0 result.stream_errors

let h2_opened label = function
  | Ok opened -> opened
  | Error `Admission_rejected -> Alcotest.failf "%s rejected by admission" label
  | Error `Connection_closed -> Alcotest.failf "%s rejected by closed connection" label

let h2_stream_of_result label result =
  match result.mux_stream with
  | Some stream -> stream
  | None -> Alcotest.failf "%s did not record stream" label

let h2_response_body label = function
  | Some body -> body
  | None -> Alcotest.failf "%s did not receive response body" label

let h2_response_writer label = function
  | Some body -> body
  | None -> Alcotest.failf "%s did not install response writer" label

let h2_body_pump_effect client server =
  Eta.Effect.sync (fun () ->
      let client_progress = h2_drain_client_to_server client server in
      let server_progress = h2_drain_server_to_client server client in
      if client_progress || server_progress then Eta_http.H2.Multiplexer.Read 1
      else Eta_http.H2.Multiplexer.Eof 0)

let h2_body_closed_error =
  Eta_http.Error.make ~protocol:H2 ~method_:"GET" ~uri:"https://api.example.test/"
    (Connection_closed { during = Http_response })

let h2_open_streaming_body mux client server held_writer body_ref =
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
      `GET "/stream"
  in
  let opened =
    Eta_http.H2.Multiplexer.request mux ~tag:1 request
      ~error_handler:(fun _ error ->
        Alcotest.failf "unexpected h2 stream error: %s"
          (h2_pp_client_error error))
      ~response_handler:(fun stream response body ->
        Alcotest.(check int) "status" 200 (H2.Status.to_code response.status);
        body_ref :=
          Some
            (Eta_http.H2.Multiplexer.body_stream
               ~closed_error:h2_body_closed_error
               ~pump:(fun () -> h2_body_pump_effect client server)
               mux stream body))
  in
  let opened =
    match opened with
    | Ok opened -> opened
    | Error Eta_http.H2.Multiplexer.Admission_rejected ->
        Alcotest.fail "streaming body rejected by admission"
    | Error Eta_http.H2.Multiplexer.Connection_closed ->
        Alcotest.fail "streaming body saw closed connection"
  in
  H2.Body.Writer.close opened.request_body;
  h2_pump_pair client server;
  h2_response_writer "streaming body" !held_writer

let test_h2_body_stream_releases_on_eof () =
  let held_writer = ref None in
  let server =
    H2.Server_connection.create (fun reqd ->
        held_writer :=
          Some (H2.Reqd.respond_with_streaming reqd (H2.Response.create `OK)))
  in
  let mux = h2_mux_create (h2_mux_result ()) () in
  let client = Eta_http.H2.Multiplexer.client_connection mux in
  let body_ref = ref None in
  let writer = h2_open_streaming_body mux client server held_writer body_ref in
  H2.Body.Writer.write_string writer "hello";
  H2.Body.Writer.close writer;
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let body =
    Eta_http.Body.Stream.read_all (h2_response_body "eof" !body_ref)
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "hello" (Bytes.to_string body);
  let stats = Eta_http.H2.Multiplexer.stats mux in
  Alcotest.(check int) "active" 0 stats.active;
  Alcotest.(check int) "live" 0 stats.live;
  Alcotest.(check int) "completed" 1 stats.completed;
  Alcotest.(check int) "local resets" 0 stats.local_resets

let test_h2_body_stream_reads_inline_data_after_header_pump () =
  let body_ref = ref None in
  let server =
    H2.Server_connection.create (fun reqd ->
        H2.Reqd.respond_with_string reqd (H2.Response.create `Not_found)
          "hello-inline")
  in
  let mux = h2_mux_create (h2_mux_result ()) () in
  let client = Eta_http.H2.Multiplexer.client_connection mux in
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
      `GET "/inline"
  in
  let opened =
    Eta_http.H2.Multiplexer.request mux ~tag:1 request
      ~error_handler:(fun _ error ->
        Alcotest.failf "unexpected h2 stream error: %s"
          (h2_pp_client_error error))
      ~response_handler:(fun stream response body ->
        Alcotest.(check int) "status" 404 (H2.Status.to_code response.status);
        body_ref :=
          Some
            (Eta_http.H2.Multiplexer.body_stream
               ~closed_error:h2_body_closed_error
               ~pump:(fun () -> h2_body_pump_effect client server)
               mux stream body))
  in
  let opened =
    match opened with
    | Ok opened -> opened
    | Error Eta_http.H2.Multiplexer.Admission_rejected ->
        Alcotest.fail "inline body rejected by admission"
    | Error Eta_http.H2.Multiplexer.Connection_closed ->
        Alcotest.fail "inline body saw closed connection"
  in
  H2.Body.Writer.close opened.request_body;
  h2_pump_pair client server;
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let body =
    Eta_http.Body.Stream.read_all (h2_response_body "inline" !body_ref)
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "hello-inline" (Bytes.to_string body);
  let stats = Eta_http.H2.Multiplexer.stats mux in
  Alcotest.(check int) "active" 0 stats.active;
  Alcotest.(check int) "completed" 1 stats.completed

let test_h2_body_stream_discard_releases_active_stream () =
  let held_writer = ref None in
  let server =
    H2.Server_connection.create (fun reqd ->
        held_writer :=
          Some (H2.Reqd.respond_with_streaming reqd (H2.Response.create `OK)))
  in
  let mux = h2_mux_create (h2_mux_result ()) () in
  let client = Eta_http.H2.Multiplexer.client_connection mux in
  let body_ref = ref None in
  let writer = h2_open_streaming_body mux client server held_writer body_ref in
  H2.Body.Writer.write_string writer "prefix";
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let body = h2_response_body "discard" !body_ref in
  let chunk =
    Eta_http.Body.Stream.read body |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check (option string)) "first chunk" (Some "prefix")
    (Option.map Bytes.to_string chunk);
  Eta_http.Body.Stream.discard body |> Eta.Runtime.run rt
  |> Eta_test.Expect.expect_ok;
  let stats = Eta_http.H2.Multiplexer.stats mux in
  Alcotest.(check int) "active" 0 stats.active;
  Alcotest.(check int) "live" 0 stats.live;
  Alcotest.(check int) "local reset" 1 stats.local_resets

let test_h2_multiplexer_sustains_100_concurrent_gets () =
  let connection_result = h2_mux_result () in
  let server =
    H2.Server_connection.create (fun reqd ->
        let target = (H2.Reqd.request reqd).target in
        H2.Reqd.respond_with_string reqd (H2.Response.create `OK)
          ("get:" ^ target))
  in
  let mux = h2_mux_create connection_result () in
  let client = Eta_http.H2.Multiplexer.client_connection mux in
  let results = List.init 100 (fun _ -> h2_mux_result ()) in
  List.iteri
    (fun i result ->
      ignore
        (h2_opened "concurrent GET"
           (h2_open_mux_request ~tag:i
              ~target:(Printf.sprintf "/concurrent/%d" i)
              mux result)))
    results;
  h2_pump_pair client server;
  List.iteri
    (fun i result ->
      Alcotest.(check (option int)) "status" (Some 200) result.mux_status;
      Alcotest.(check string) "body"
        (Printf.sprintf "get:/concurrent/%d" i)
        (Buffer.contents result.mux_body);
      Alcotest.(check bool) "eof" true result.mux_eof;
      Alcotest.(check int) "stream errors" 0
        (List.length result.mux_stream_errors);
      Alcotest.(check bool) "release complete" true
        (Eta_http.H2.Multiplexer.release mux
           (h2_stream_of_result "concurrent GET" result)
        = Eta_http.H2.Stream_state.No_rst))
    results;
  Alcotest.(check int) "connection errors" 0
    (List.length connection_result.mux_client_errors);
  let stats = Eta_http.H2.Multiplexer.stats mux in
  Alcotest.(check int) "active" 0 stats.active;
  Alcotest.(check int) "cancelled" 0 stats.cancelled;
  Alcotest.(check int) "live" 0 stats.live;
  Alcotest.(check int) "opened" 100 stats.opened;
  Alcotest.(check int) "completed" 100 stats.completed;
  Alcotest.(check int) "max inflight" 100 stats.max_inflight

let test_h2_multiplexer_upload_flow_control_resumes () =
  let connection_result = h2_mux_result () in
  let held = ref None in
  let server =
    H2.Server_connection.create (fun reqd ->
        match (H2.Reqd.request reqd).meth, (H2.Reqd.request reqd).target with
        | `POST, "/upload-hold" -> held := Some reqd
        | _ ->
            H2.Reqd.respond_with_string reqd (H2.Response.create `OK)
              "unexpected")
  in
  let mux = h2_mux_create connection_result () in
  let client = Eta_http.H2.Multiplexer.client_connection mux in
  let result = h2_mux_result () in
  let payload = String.make (128 * 1024) 'x' in
  ignore
    (h2_opened "upload"
       (h2_open_mux_request ~meth:`POST ~body:payload ~target:"/upload-hold"
          mux result));
  h2_pump_pair client server;
  Alcotest.(check (option int)) "no response before server body read" None
    result.mux_status;
  let reqd =
    match !held with
    | Some reqd -> reqd
    | None -> Alcotest.fail "server did not hold upload request"
  in
  h2_server_read_body reqd ~on_done:(fun body ->
      H2.Reqd.respond_with_string reqd (H2.Response.create `OK)
        (Printf.sprintf "upload:%d" (String.length body)));
  h2_pump_pair client server;
  Alcotest.(check (option int)) "status" (Some 200) result.mux_status;
  Alcotest.(check string) "body" "upload:131072"
    (Buffer.contents result.mux_body);
  Alcotest.(check bool) "eof" true result.mux_eof;
  Alcotest.(check bool) "release complete" true
    (Eta_http.H2.Multiplexer.release mux
       (h2_stream_of_result "upload" result)
    = Eta_http.H2.Stream_state.No_rst);
  Alcotest.(check int) "connection errors" 0
    (List.length connection_result.mux_client_errors)

let test_h2_multiplexer_server_reset_admission_release () =
  let connection_result = h2_mux_result () in
  let server =
    H2.Server_connection.create (fun reqd ->
        let body =
          H2.Reqd.respond_with_streaming reqd (H2.Response.create `OK)
        in
        H2.Body.Writer.write_string body "partial";
        H2.Reqd.report_exn reqd (Failure "reset-fixture"))
  in
  let mux = h2_mux_create ~max_concurrent:32 connection_result () in
  let client = Eta_http.H2.Multiplexer.client_connection mux in
  let results = List.init 32 (fun _ -> h2_mux_result ()) in
  List.iteri
    (fun i result ->
      ignore
        (h2_opened "reset"
           (h2_open_mux_request ~tag:i ~target:"/rst" mux result)))
    results;
  h2_pump_pair client server;
  List.iter
    (fun result ->
      Alcotest.(check bool) "stream error observed" true
        (List.length result.mux_stream_errors > 0))
    results;
  let stats_after_reset = Eta_http.H2.Multiplexer.stats mux in
  Alcotest.(check int) "active after reset" 0 stats_after_reset.active;
  Alcotest.(check int) "cancelled after reset" 32 stats_after_reset.cancelled;
  Alcotest.(check int) "live after reset" 32 stats_after_reset.live;
  Alcotest.(check int) "remote resets" 32 stats_after_reset.remote_resets;
  let rejected =
    List.init 100 (fun i ->
        let result = h2_mux_result () in
        match h2_open_mux_request ~tag:(1000 + i) ~target:"/rst" mux result with
        | Error `Admission_rejected -> 1
        | Error `Connection_closed -> Alcotest.fail "connection closed"
        | Ok _ -> Alcotest.fail "cancelled streams should still occupy admission")
    |> List.fold_left ( + ) 0
  in
  Alcotest.(check int) "rejected while cancelled admitted" 100 rejected;
  List.iter
    (fun result ->
      Alcotest.(check bool) "remote reset release" true
        (Eta_http.H2.Multiplexer.release mux
           (h2_stream_of_result "reset" result)
        = Eta_http.H2.Stream_state.No_rst))
    results;
  let stats = Eta_http.H2.Multiplexer.stats mux in
  Alcotest.(check int) "active final" 0 stats.active;
  Alcotest.(check int) "cancelled final" 0 stats.cancelled;
  Alcotest.(check int) "live final" 0 stats.live;
  Alcotest.(check int) "completed" 32 stats.completed;
  Alcotest.(check int) "admission rejected" 100 stats.admission_rejected;
  Alcotest.(check int) "max inflight" 32 stats.max_inflight;
  Alcotest.(check int) "connection errors" 0
    (List.length connection_result.mux_client_errors)

let test_h2_multiplexer_client_cancel_releases_stream () =
  let connection_result = h2_mux_result () in
  let server =
    H2.Server_connection.create (fun reqd ->
        match (H2.Reqd.request reqd).target with
        | "/slow" ->
            let body =
              H2.Reqd.respond_with_streaming reqd (H2.Response.create `OK)
            in
            H2.Body.Writer.write_string body "slow-prefix"
        | target ->
            H2.Reqd.respond_with_string reqd (H2.Response.create `OK)
              ("get:" ^ target))
  in
  let mux = h2_mux_create connection_result () in
  let client = Eta_http.H2.Multiplexer.client_connection mux in
  let first = h2_mux_result () in
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
      `GET "/slow"
  in
  let opened =
    match
      Eta_http.H2.Multiplexer.request mux ~tag:1 request
        ~error_handler:(fun stream error ->
          first.mux_stream <- Some stream;
          first.mux_stream_errors <-
            h2_pp_client_error error :: first.mux_stream_errors)
        ~response_handler:(fun stream response response_body ->
          first.mux_stream <- Some stream;
          first.mux_status <- Some (H2.Status.to_code response.status);
          H2.Body.Reader.schedule_read response_body
            ~on_eof:(fun () -> Alcotest.fail "slow response ended early")
            ~on_read:(fun bs ~off ~len ->
              Buffer.add_string first.mux_body
                (Bigstringaf.substring bs ~off ~len);
              first.mux_release <-
                Some (Eta_http.H2.Multiplexer.release mux stream)))
    with
    | Ok opened -> opened
    | Error Eta_http.H2.Multiplexer.Admission_rejected ->
        Alcotest.fail "slow request rejected"
    | Error Eta_http.H2.Multiplexer.Connection_closed ->
        Alcotest.fail "slow request saw closed connection"
  in
  H2.Body.Writer.close opened.request_body;
  h2_pump_pair client server;
  Alcotest.(check (option int)) "slow status" (Some 200) first.mux_status;
  Alcotest.(check string) "first chunk" "slow-prefix"
    (Buffer.contents first.mux_body);
  Alcotest.(check bool) "released active stream" true
    (first.mux_release = Some Eta_http.H2.Stream_state.Queue_rst);
  let after = h2_mux_result () in
  ignore
    (h2_opened "after cancel"
       (h2_open_mux_request ~tag:2 ~target:"/after-cancel" mux after));
  h2_pump_pair client server;
  Alcotest.(check (option int)) "after status" (Some 200) after.mux_status;
  Alcotest.(check string) "after body" "get:/after-cancel"
    (Buffer.contents after.mux_body);
  Alcotest.(check bool) "after release" true
    (Eta_http.H2.Multiplexer.release mux
       (h2_stream_of_result "after cancel" after)
    = Eta_http.H2.Stream_state.No_rst);
  let stats = Eta_http.H2.Multiplexer.stats mux in
  Alcotest.(check int) "active final" 0 stats.active;
  Alcotest.(check int) "live final" 0 stats.live;
  Alcotest.(check int) "local resets" 1 stats.local_resets;
  Alcotest.(check int) "connection errors" 0
    (List.length connection_result.mux_client_errors)

let h2_chr n = Char.chr n

let h2_frame_header ~length ~frame_type ~flags ~stream_id =
  String.init 9 @@ function
  | 0 -> h2_chr ((length lsr 16) land 0xff)
  | 1 -> h2_chr ((length lsr 8) land 0xff)
  | 2 -> h2_chr (length land 0xff)
  | 3 -> h2_chr frame_type
  | 4 -> h2_chr flags
  | 5 -> h2_chr ((stream_id lsr 24) land 0x7f)
  | 6 -> h2_chr ((stream_id lsr 16) land 0xff)
  | 7 -> h2_chr ((stream_id lsr 8) land 0xff)
  | 8 -> h2_chr (stream_id land 0xff)
  | _ -> assert false

let h2_uint32 n =
  String.init 4 @@ function
  | 0 -> h2_chr ((n lsr 24) land 0xff)
  | 1 -> h2_chr ((n lsr 16) land 0xff)
  | 2 -> h2_chr ((n lsr 8) land 0xff)
  | 3 -> h2_chr (n land 0xff)
  | _ -> assert false

let h2_settings_frame =
  h2_frame_header ~length:0 ~frame_type:0x4 ~flags:0 ~stream_id:0

let h2_goaway_no_error ~last_stream_id =
  h2_frame_header ~length:8 ~frame_type:0x7 ~flags:0 ~stream_id:0
  ^ h2_uint32 last_stream_id
  ^ h2_uint32 0

let h2_payload len = String.make len '\000'

let h2_observe_security data =
  let security = Eta_http.H2.Security.create () in
  let bs = Bigstringaf.of_string ~off:0 ~len:(String.length data) data in
  Eta_http.H2.Security.observe security bs ~off:0 ~len:(String.length data)

let test_h2_security_settings_churn_reader () =
  let client =
    H2.Client_connection.create
      ~error_handler:(fun _ -> Alcotest.fail "unexpected h2 client error")
      ()
  in
  let reader = Eta_http.H2.Multiplexer.create_client_reader ~buffer_size:64 client in
  let source =
    Eio.Flow.cstruct_source
      (h2_cstruct_chunks ~chunk_size:11 (String.concat "" (List.init 11 (fun _ -> h2_settings_frame))))
  in
  let rec loop attempts =
    if attempts = 0 then Alcotest.fail "settings churn was not detected"
    else
      match Eta_http.H2.Multiplexer.read_client_once ~flow:source reader with
      | Security_error (Settings_churn_rate_exceeded { observed_rate_hz; limit_hz }) ->
          Alcotest.(check int) "observed" 11 observed_rate_hz;
          Alcotest.(check int) "limit" 10 limit_hz
      | Security_error kind ->
          Alcotest.failf "unexpected security error: %s"
            (Eta_http.Error.kind_name kind)
      | Read _ | Eof _ -> loop (attempts - 1)
      | Close -> Alcotest.fail "client closed before settings churn detection"
  in
  loop 32

let test_h2_security_hpack_block_cap () =
  let frame =
    h2_frame_header ~length:(300 * 1024) ~frame_type:0x1 ~flags:0x4
      ~stream_id:1
  in
  match h2_observe_security frame with
  | Some (Hpack_decode_overflow { decoded_bytes; limit_bytes }) ->
      Alcotest.(check int) "decoded" (300 * 1024) decoded_bytes;
      Alcotest.(check int) "limit" (256 * 1024) limit_bytes
  | Some kind ->
      Alcotest.failf "unexpected security error: %s"
        (Eta_http.Error.kind_name kind)
  | None -> Alcotest.fail "hpack block cap was not detected"

let test_h2_security_continuation_cap () =
  let data =
    h2_frame_header ~length:(40 * 1024) ~frame_type:0x1 ~flags:0
      ~stream_id:1
    ^ h2_payload (40 * 1024)
    ^ h2_frame_header ~length:(30 * 1024) ~frame_type:0x9 ~flags:0x4
        ~stream_id:1
  in
  match h2_observe_security data with
  | Some (Continuation_flood { accumulated_bytes; limit_bytes; frames }) ->
      Alcotest.(check int) "accumulated" (70 * 1024) accumulated_bytes;
      Alcotest.(check int) "limit" (64 * 1024) limit_bytes;
      Alcotest.(check int) "frames" 2 frames
  | Some kind ->
      Alcotest.failf "unexpected security error: %s"
        (Eta_http.Error.kind_name kind)
  | None -> Alcotest.fail "continuation cap was not detected"

let test_h2_security_goaway_churn () =
  let data =
    h2_goaway_no_error ~last_stream_id:1
    ^ h2_goaway_no_error ~last_stream_id:1
  in
  match h2_observe_security data with
  | Some (Connection_closed { during = Http_response }) -> ()
  | Some kind ->
      Alcotest.failf "unexpected security error: %s"
        (Eta_http.Error.kind_name kind)
  | None -> Alcotest.fail "GOAWAY churn was not detected"

let test_h2_security_header_churn () =
  let frame =
    h2_frame_header ~length:0 ~frame_type:0x1 ~flags:0x4 ~stream_id:1
  in
  let data = String.concat "" (List.init 33 (fun _ -> frame)) in
  match h2_observe_security data with
  | Some
      (Response_header_change_rate_exceeded
        { observed_rate_hz; limit_hz }) ->
      Alcotest.(check int) "observed" 33 observed_rate_hz;
      Alcotest.(check int) "limit" 32 limit_hz
  | Some kind ->
      Alcotest.failf "unexpected security error: %s"
        (Eta_http.Error.kind_name kind)
  | None -> Alcotest.fail "header churn was not detected"

let expect_header_invalid label headers =
  match Eta_http.H2.Security.validate_headers headers with
  | Some (Header_invalid _) -> ()
  | Some kind ->
      Alcotest.failf "%s unexpected error: %s" label
        (Eta_http.Error.kind_name kind)
  | None -> Alcotest.failf "%s was accepted" label

let test_h2_security_header_normalization_edges () =
  expect_header_invalid "empty" [ "", "value" ];
  expect_header_invalid "nul name" [ "x\000bad", "value" ];
  expect_header_invalid "nul value" [ "x-good", "bad\000value" ];
  expect_header_invalid "uppercase" [ "X-Bad", "value" ];
  expect_header_invalid "long name" [ String.make (8 * 1024 + 1) 'x', "value" ];
  expect_header_invalid "long value" [ "x-good", String.make (64 * 1024 + 1) 'x' ];
  Alcotest.(check bool) "valid" true
    (Option.is_none
       (Eta_http.H2.Security.validate_headers [ "x-good", "value" ]))

let rec h2_drain_client_writes client =
  match H2.Client_connection.next_write_operation client with
  | `Write iovecs ->
      let data = h2_iovecs_to_string iovecs in
      H2.Client_connection.report_write_result client (`Ok (String.length data));
      1 + h2_drain_client_writes client
  | `Yield -> 0
  | `Close _ ->
      H2.Client_connection.report_write_result client `Closed;
      0

let test_h2_multiplexer_rejects_after_goaway () =
  let connection_result = h2_mux_result () in
  let mux = h2_mux_create connection_result () in
  let client = Eta_http.H2.Multiplexer.client_connection mux in
  let first = h2_mux_result () in
  ignore
    (h2_opened "before GOAWAY"
       (h2_open_mux_request ~tag:1 ~target:"/before-goaway" mux first));
  ignore (h2_drain_client_writes client);
  h2_feed_client client (h2_settings_frame ^ h2_goaway_no_error ~last_stream_id:1);
  Alcotest.(check bool) "open before GOAWAY flush" false
    (H2.Client_connection.is_closed client);
  ignore (h2_drain_client_writes client);
  Alcotest.(check bool) "closed after GOAWAY flush" true
    (H2.Client_connection.is_closed client);
  let after = h2_mux_result () in
  (match h2_open_mux_request ~tag:2 ~target:"/after-goaway" mux after with
  | Error `Connection_closed -> ()
  | Error `Admission_rejected -> Alcotest.fail "GOAWAY reported as admission pressure"
  | Ok _ -> Alcotest.fail "post-GOAWAY request was admitted");
  let stats = Eta_http.H2.Multiplexer.stats mux in
  Alcotest.(check int) "opened before only" 1 stats.opened;
  Alcotest.(check int) "no admission pressure" 0 stats.admission_rejected

let test_alpn_state_collapses_pending_first_arrivals () =
  let alpn = Eta_http.Transport.Alpn.create () in
  let leader =
    match Eta_http.Transport.Alpn.begin_request alpn with
    | Leader pending -> pending
    | Wait _ | Ready _ -> Alcotest.fail "expected first request leader"
  in
  let waiter =
    match Eta_http.Transport.Alpn.begin_request alpn with
    | Wait pending -> pending
    | Leader _ | Ready _ -> Alcotest.fail "expected second request waiter"
  in
  Alcotest.(check int) "same pending"
    (Eta_http.Transport.Alpn.pending_id leader)
    (Eta_http.Transport.Alpn.pending_id waiter);
  (match Eta_http.Transport.Alpn.resolve alpn leader H2 with
  | Installed H2 -> ()
  | _ -> Alcotest.fail "expected h2 installation");
  (match Eta_http.Transport.Alpn.begin_request alpn with
  | Ready H2 -> ()
  | Leader _ | Wait _ | Ready H1 -> Alcotest.fail "expected h2 ready route");
  let stats = Eta_http.Transport.Alpn.stats alpn in
  Alcotest.(check int) "leaders" 1 stats.leaders;
  Alcotest.(check int) "waiters" 1 stats.waiters;
  Alcotest.(check int) "redundant cancelled" 1 stats.redundant_cancelled;
  Alcotest.(check int) "h2 resolved" 1 stats.h2_resolved

let test_alpn_state_ignores_stale_resolution_and_decodes_protocols () =
  let alpn = Eta_http.Transport.Alpn.create () in
  let first =
    match Eta_http.Transport.Alpn.begin_request alpn with
    | Leader pending -> pending
    | Wait _ | Ready _ -> Alcotest.fail "expected first leader"
  in
  Eta_http.Transport.Alpn.cancel alpn first;
  let second =
    match Eta_http.Transport.Alpn.begin_request alpn with
    | Leader pending -> pending
    | Wait _ | Ready _ -> Alcotest.fail "expected second leader"
  in
  (match Eta_http.Transport.Alpn.resolve alpn first H2 with
  | Ignored -> ()
  | Installed _ | Already_ready _ -> Alcotest.fail "stale pending resolved");
  (match Eta_http.Transport.Alpn.resolve alpn second H1 with
  | Installed H1 -> ()
  | _ -> Alcotest.fail "expected h1 installation");
  Alcotest.(check (result bool string)) "decode h2" (Ok true)
    (Result.map (( = ) Eta_http.Transport.Alpn.H2)
       (Eta_http.Transport.Alpn.protocol_of_alpn (Some "h2")));
  Alcotest.(check (result bool string)) "decode h1" (Ok true)
    (Result.map (( = ) Eta_http.Transport.Alpn.H1)
       (Eta_http.Transport.Alpn.protocol_of_alpn (Some "http/1.1")));
  Alcotest.(check (result bool string)) "missing ALPN falls back h1" (Ok true)
    (Result.map (( = ) Eta_http.Transport.Alpn.H1)
       (Eta_http.Transport.Alpn.protocol_of_alpn None));
  Alcotest.(check (result bool string)) "unknown ALPN rejected" (Error "spdy/3")
    (Result.map (( = ) Eta_http.Transport.Alpn.H1)
       (Eta_http.Transport.Alpn.protocol_of_alpn (Some "spdy/3")))

let test_dispatch_decides_alpn_route () =
  (match Eta_http.Transport.Dispatch.decide_alpn (Some "h2") with
  | Ok Use_h2 -> ()
  | Ok Use_h1 -> Alcotest.fail "h2 ALPN routed to h1"
  | Error protocol -> Alcotest.failf "h2 ALPN rejected: %s" protocol);
  (match Eta_http.Transport.Dispatch.decide_alpn (Some "http/1.1") with
  | Ok Use_h1 -> ()
  | Ok Use_h2 -> Alcotest.fail "http/1.1 ALPN routed to h2"
  | Error protocol -> Alcotest.failf "http/1.1 ALPN rejected: %s" protocol);
  (match Eta_http.Transport.Dispatch.decide_alpn None with
  | Ok Use_h1 -> ()
  | Ok Use_h2 -> Alcotest.fail "missing ALPN routed to h2"
  | Error protocol -> Alcotest.failf "missing ALPN rejected: %s" protocol);
  Alcotest.(check (result string string)) "unknown ALPN" (Error "spdy/3")
    (Result.map
       (fun decision ->
         Eta_http.Transport.Dispatch.protocol_to_string
           (Eta_http.Transport.Dispatch.decision_protocol decision))
       (Eta_http.Transport.Dispatch.decide_alpn (Some "spdy/3")))

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
          Alcotest.test_case "reader release once" `Quick
            test_body_stream_reader_release_once;
          Alcotest.test_case "chunked trailers" `Quick
            test_chunked_decodes_trailers;
          Alcotest.test_case "gzip roundtrip" `Quick
            test_gzip_transducer_roundtrip;
          Alcotest.test_case "gzip expansion cap" `Quick
            test_gzip_transducer_expansion_cap;
          Alcotest.test_case "gzip truncated stream" `Quick
            test_gzip_transducer_rejects_truncated_stream;
          Alcotest.test_case "gzip CRC mismatch" `Quick
            test_gzip_transducer_rejects_crc_mismatch;
          Alcotest.test_case "gzip concatenated members" `Quick
            test_gzip_transducer_decodes_concatenated_members;
        ] );
      ( "client",
        [
          Alcotest.test_case "make_h1 request path" `Quick
            test_client_make_h1_request_path;
        ] );
      ( "retry",
        [
          Alcotest.test_case "idempotency classifier" `Quick
            test_idempotency_classifier;
          Alcotest.test_case "Retry-After parser" `Quick
            test_retry_after_parser;
          Alcotest.test_case "schedule backoff" `Quick
            test_retry_policy_schedule_backoff;
          Alcotest.test_case "succeeds on third attempt" `Quick
            test_retry_succeeds_on_third_attempt;
          Alcotest.test_case "non-idempotent requires opt-in" `Quick
            test_retry_non_idempotent_requires_opt_in;
          Alcotest.test_case "always requires replayable body" `Quick
            test_retry_always_still_requires_replayable_body;
        ] );
      ( "observability",
        [
          Alcotest.test_case "successful GET semconv" `Quick
            test_observability_success_get_semconv;
          Alcotest.test_case "DNS error semconv" `Quick
            test_observability_dns_error_semconv;
          Alcotest.test_case "TLS error semconv" `Quick
            test_observability_tls_error_semconv;
          Alcotest.test_case "retry success spans" `Quick
            test_observability_retry_success_spans;
          Alcotest.test_case "redirect semconv" `Quick
            test_observability_redirect_semconv;
          Alcotest.test_case "h2 protocol attrs" `Quick
            test_observability_h2_protocol_attrs;
          Alcotest.test_case "recursion disabled" `Quick
            test_observability_recursion_disabled;
          Alcotest.test_case "pool stats meter" `Quick
            test_observability_pool_stats_meter;
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
          Alcotest.test_case "decodes chunked response" `Quick
            test_h1_client_decodes_chunked_response;
          Alcotest.test_case "streaming request body releases" `Quick
            test_h1_client_streaming_request_body_releases;
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
          Alcotest.test_case "pool cancellation releases checkout" `Quick
            test_h1_pool_request_cancellation_releases_checkout;
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
      ( "alpn",
        [
          Alcotest.test_case "pending first-arrivals collapse" `Quick
            test_alpn_state_collapses_pending_first_arrivals;
          Alcotest.test_case "stale resolution and decode" `Quick
            test_alpn_state_ignores_stale_resolution_and_decodes_protocols;
        ] );
      ( "dispatch",
        [
          Alcotest.test_case "ALPN route decision" `Quick
            test_dispatch_decides_alpn_route;
        ] );
      ( "tls",
        [
          Alcotest.test_case "chokepoint policy" `Quick
            test_tls_chokepoint_policy;
        ] );
      ( "h2-admission",
        [
          Alcotest.test_case "cancelled counts until release" `Quick
            test_h2_admission_counts_cancelled_until_release;
        ] );
      ( "h2-stream-state",
        [
          Alcotest.test_case "release decisions" `Quick
            test_h2_stream_state_release_decisions;
          Alcotest.test_case "close releases live state" `Quick
            test_h2_stream_state_close_releases_live_state;
        ] );
      ( "h2-writer",
        [
          Alcotest.test_case "preserves iovec slices" `Quick
            test_h2_writer_preserves_iovec_slices;
          Alcotest.test_case "drains client preface and request" `Quick
            test_h2_writer_drains_client_preface_and_request;
          Alcotest.test_case "blocked write teardown" `Quick
            test_h2_writer_blocked_write_teardown;
        ] );
      ( "h2-security",
        [
          Alcotest.test_case "SETTINGS churn reader" `Quick
            test_h2_security_settings_churn_reader;
          Alcotest.test_case "HPACK block cap" `Quick
            test_h2_security_hpack_block_cap;
          Alcotest.test_case "CONTINUATION cap" `Quick
            test_h2_security_continuation_cap;
          Alcotest.test_case "GOAWAY churn" `Quick
            test_h2_security_goaway_churn;
          Alcotest.test_case "header churn" `Quick
            test_h2_security_header_churn;
          Alcotest.test_case "header normalization edges" `Quick
            test_h2_security_header_normalization_edges;
        ] );
      ( "h2-multiplexer",
        [
          Alcotest.test_case "reads server response" `Quick
            test_h2_multiplexer_reads_server_response;
          Alcotest.test_case "body stream releases on EOF" `Quick
            test_h2_body_stream_releases_on_eof;
          Alcotest.test_case "body stream reads inline data" `Quick
            test_h2_body_stream_reads_inline_data_after_header_pump;
          Alcotest.test_case "body stream discard releases" `Quick
            test_h2_body_stream_discard_releases_active_stream;
          Alcotest.test_case "100 concurrent GETs" `Quick
            test_h2_multiplexer_sustains_100_concurrent_gets;
          Alcotest.test_case "upload flow-control resumes" `Quick
            test_h2_multiplexer_upload_flow_control_resumes;
          Alcotest.test_case "server reset admission release" `Quick
            test_h2_multiplexer_server_reset_admission_release;
          Alcotest.test_case "client cancel releases stream" `Quick
            test_h2_multiplexer_client_cancel_releases_stream;
          Alcotest.test_case "GOAWAY rejects new streams" `Quick
            test_h2_multiplexer_rejects_after_goaway;
        ] );
    ]
