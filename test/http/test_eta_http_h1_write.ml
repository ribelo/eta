open Test_eta_http_support

let expect_h1_content_length_flow_invalid label buffer = function
  | Error { Eta_http.Error.kind = Header_invalid { reason }; _ } ->
      Alcotest.(check bool)
        (label ^ " mentions Content-Length")
        true
        (contains reason "Content-Length");
      Alcotest.(check string) (label ^ " emitted nothing") ""
        (Buffer.contents buffer)
  | Error error ->
      Alcotest.failf "%s unexpected error: %s" label
        (Eta_http.Error.to_string error)
  | Ok () ->
      Alcotest.failf "%s serialized invalid request: %S" label
        (Buffer.contents buffer)

let test_h1_writer_rejects_invalid_content_length_framing () =
  let url = Eta_http.Core.Url.of_string "http://example.test/echo" in
  let cases =
    [
      ( "mismatch",
        [ ("Content-Length", "3") ],
        Eta_http.H1.Write.Fixed [ Bytes.of_string "abcdef" ] );
      ( "invalid",
        [ ("Content-Length", "nope") ],
        Eta_http.H1.Write.Fixed [ Bytes.of_string "abcdef" ] );
      ( "duplicate conflict",
        [ ("Content-Length", "6"); ("Content-Length", "3") ],
        Eta_http.H1.Write.Fixed [ Bytes.of_string "abcdef" ] );
      ( "empty mismatch",
        [ ("Content-Length", "1") ],
        Eta_http.H1.Write.Empty );
      ( "content length with transfer encoding",
        [ ("Content-Length", "6"); ("Transfer-Encoding", "chunked") ],
        Eta_http.H1.Write.Fixed [ Bytes.of_string "abcdef" ] );
    ]
  in
  List.iter
    (fun (label, headers, body) ->
      let buffer = Buffer.create 128 in
      let flow = Eio.Flow.buffer_sink buffer in
      Eta_http_eio.H1.Write.write_to_flow flow ~method_:"POST" ~url ~headers
        ~body
      |> expect_h1_content_length_flow_invalid label buffer)
    cases

let test_h1_writer_rejects_transfer_encoding_for_fixed_body () =
  let url = Eta_http.Core.Url.of_string "http://example.test/echo" in
  let headers = [ ("Transfer-Encoding", "chunked") ] in
  let body = Eta_http.H1.Write.Fixed [ Bytes.of_string "abcdef" ] in
  let buffer = Buffer.create 128 in
  let flow = Eio.Flow.buffer_sink buffer in
  match
    Eta_http_eio.H1.Write.write_to_flow flow ~method_:"POST" ~url ~headers ~body
  with
  | Error { Eta_http.Error.kind = Header_invalid { reason }; _ } ->
      Alcotest.(check bool)
        "flow mentions Transfer-Encoding" true
        (contains reason "Transfer-Encoding");
      Alcotest.(check string) "flow emitted nothing" "" (Buffer.contents buffer)
  | Error error -> Alcotest.fail (Eta_http.Error.to_string error)
  | Ok () ->
      Alcotest.failf "flow serialized invalid request: %S"
        (Buffer.contents buffer)

let test_h1_writer_stream_override_does_not_reframe_fixed_body () =
  let url = Eta_http.Core.Url.of_string "http://example.test/echo" in
  let buffer = Buffer.create 128 in
  let flow = Eio.Flow.buffer_sink buffer in
  match
    Eta_http_eio.H1.Write.write_to_flow ~framing_body_length:3 flow ~method_:"POST"
      ~url ~headers:[ ("Content-Length", "3") ]
      ~body:(Eta_http.H1.Write.Fixed [ Bytes.of_string "abcdef" ])
  with
  | Error { Eta_http.Error.kind = Header_invalid { reason }; _ } ->
      Alcotest.(check bool)
        "fixed override mentions Content-Length" true
        (contains reason "Content-Length");
      Alcotest.(check string) "fixed override emitted nothing" ""
        (Buffer.contents buffer)
  | Error error -> Alcotest.fail (Eta_http.Error.to_string error)
  | Ok () ->
      Alcotest.failf "fixed override serialized invalid request: %S"
        (Buffer.contents buffer)

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
      Eta_http_eio.H1.Write.write_to_flow flow ~method_:"POST" ~url ~headers:[]
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
    Eta_http_eio.H1.Write.write_to_flow flow ~method_:"POST" ~url ~headers:[]
      ~body:(Eta_http.H1.Write.Fixed [ Bytes.of_string "abc" ])
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
    Eta_http_eio.H1.Write.write_to_flow flow ~method_:"POST" ~url ~headers:[]
      ~body:(Eta_http.H1.Write.Fixed [ Bytes.of_string "abc" ])
  with
  | exception Eio.Cancel.Cancelled _ -> ()
  | Error error ->
      Alcotest.failf "flow write cancellation became typed failure: %s"
        (Eta_http.Error.to_string error)
  | Ok () -> Alcotest.fail "flow write cancellation unexpectedly succeeded"

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

let test_h1_writer_rejects_header_injection () =
  let url = Eta_http.Core.Url.of_string "http://example.test/injection" in
  List.iter
    (fun (label, headers) ->
      let buffer = Buffer.create 128 in
      let flow = Eio.Flow.buffer_sink buffer in
      match
        Eta_http_eio.H1.Write.write_to_flow flow ~method_:"GET" ~url ~headers
          ~body:Eta_http.H1.Write.Empty
      with
      | Error { Eta_http.Error.kind = Header_invalid _; _ } ->
          Alcotest.(check string)
            (label ^ " flow emitted nothing")
            "" (Buffer.contents buffer)
      | Error error ->
          Alcotest.failf "%s flow unexpected error: %s" label
            (Eta_http.Error.to_string error)
      | Ok () ->
          Alcotest.(check bool)
            (label ^ " flow injected line absent")
            false
            (contains (Buffer.contents buffer) "injected: 1");
          Alcotest.failf "%s flow unexpectedly accepted invalid header" label)
    h1_injection_cases
