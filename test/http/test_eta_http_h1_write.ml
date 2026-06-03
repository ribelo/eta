open Test_eta_http_support

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

let test_h1_writer_flow_write_failure_is_typed () =
  let url = Eta_http.Core.Url.of_string "http://example.test/echo" in
  let flow = Eio_mock.Flow.make "eta-http-h1-write-failing-flow" in
  Eio_mock.Flow.on_copy_bytes flow
    [ `Raise (Unix.Unix_error (Unix.EPIPE, "write", "")) ];
  match
    Eta_http.H1.Write.write_to_flow flow ~method_:"POST" ~url ~headers:[]
      ~body:(Fixed [ Bytes.of_string "abc" ])
  with
  | Error { Eta_http.Error.kind = Connection_closed { during = Http_request }; _ } ->
      ()
  | Error error -> Alcotest.fail (Eta_http.Error.to_string error)
  | Ok () -> Alcotest.fail "flow write failure unexpectedly succeeded"

let test_h1_writer_flow_write_cancellation_propagates () =
  let url = Eta_http.Core.Url.of_string "http://example.test/echo" in
  let flow = Eio_mock.Flow.make "eta-http-h1-write-cancel-flow" in
  Eio_mock.Flow.on_copy_bytes flow
    [ `Raise (Eio.Cancel.Cancelled (Failure "write cancelled")) ];
  match
    Eta_http.H1.Write.write_to_flow flow ~method_:"POST" ~url ~headers:[]
      ~body:(Fixed [ Bytes.of_string "abc" ])
  with
  | exception Eio.Cancel.Cancelled _ -> ()
  | Error error ->
      Alcotest.failf "flow write cancellation became typed failure: %s"
        (Eta_http.Error.to_string error)
  | Ok () -> Alcotest.fail "flow write cancellation unexpectedly succeeded"

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

let h1_injection_cases =
  [
    ("value CRLF", [ ("X-Good", "ok\r\ninjected: 1") ]);
    ("name CRLF", [ ("x-good\r\ninjected", "1") ]);
    ("value LF", [ ("X-Good", "ok\ninjected: 1") ]);
    ("value CR", [ ("X-Good", "ok\rinjected: 1") ]);
    ("value obs-fold", [ ("X-Good", "ok\n injected: 1") ]);
    ("name NUL", [ ("x\000bad", "1") ]);
    ("value NUL", [ ("X-Good", "bad\000value") ]);
  ]

let expect_h1_header_invalid label = function
  | Error { Eta_http.Error.kind = Header_invalid _; _ } -> ()
  | Error error -> Alcotest.failf "%s unexpected error: %s" label (Eta_http.Error.to_string error)
  | Ok wire ->
      Alcotest.(check bool)
        (label ^ " injected line absent")
        false
        (contains wire "injected: 1");
      Alcotest.failf "%s unexpectedly accepted invalid header" label

let expect_h1_header_invalid_len label bytes = function
  | Error { Eta_http.Error.kind = Header_invalid _; _ } -> ()
  | Error error -> Alcotest.failf "%s unexpected error: %s" label (Eta_http.Error.to_string error)
  | Ok len ->
      let wire = Bytes.sub_string bytes 0 len in
      Alcotest.(check bool)
        (label ^ " injected line absent")
        false
        (contains wire "injected: 1");
      Alcotest.failf "%s unexpectedly accepted invalid header" label

let test_h1_writer_rejects_header_injection () =
  let url = Eta_http.Core.Url.of_string "http://example.test/injection" in
  List.iter
    (fun (label, headers) ->
      Eta_http.H1.Write.to_string ~method_:"GET" ~url ~headers
        ~body:Eta_http.H1.Write.Empty
      |> expect_h1_header_invalid (label ^ " string");
      let bytes = Bytes.create 512 in
      Eta_http.H1.Write.write_to_bytes bytes ~pos:0 ~method_:"GET" ~url
        ~headers ~body:Eta_http.H1.Write.Empty
      |> expect_h1_header_invalid_len (label ^ " bytes") bytes;
      let buffer = Buffer.create 128 in
      let flow = Eio.Flow.buffer_sink buffer in
      (match
         Eta_http.H1.Write.write_to_flow flow ~method_:"GET" ~url ~headers
           ~body:Eta_http.H1.Write.Empty
       with
      | Error { Eta_http.Error.kind = Header_invalid _; _ } ->
          Alcotest.(check string) (label ^ " flow emitted nothing") "" (Buffer.contents buffer)
      | Error error ->
          Alcotest.failf "%s flow unexpected error: %s" label
            (Eta_http.Error.to_string error)
      | Ok () ->
          Alcotest.(check bool)
            (label ^ " flow injected line absent")
            false
            (contains (Buffer.contents buffer) "injected: 1");
          Alcotest.failf "%s flow unexpectedly accepted invalid header" label))
    h1_injection_cases

