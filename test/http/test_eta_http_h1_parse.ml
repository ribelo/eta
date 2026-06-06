open Test_eta_http_support

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

let test_h1_parser_rejects_invalid_header_value_controls () =
  let raw =
    Bytes.of_string "HTTP/1.1 200 OK\r\nX-Bad: ok\000bad\r\n\r\n"
  in
  match Eta_http.H1.Parse.parse raw ~len:(Bytes.length raw) with
  | Error (Eta_http.H1.Parse.Invalid_header _) -> ()
  | Error error ->
      Alcotest.failf "expected invalid header, got %s"
        (Eta_http.H1.Parse.parse_error_to_string error)
  | Ok _ -> Alcotest.fail "control byte in header value was accepted"

