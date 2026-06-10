let test_string_helpers_prefix_suffix_contains () =
  let open Eta.String_helpers in
  Alcotest.(check bool) "starts with" true (starts_with "HTTP/1.1" ~prefix:"HTTP/");
  Alcotest.(check bool) "starts with at" true
    (starts_with_at "-- no-transaction\r\nSELECT 1" ~offset:17 "\r\n");
  Alcotest.(check bool) "negative offset" false
    (starts_with_at "abc" ~offset:(-1) "a");
  Alcotest.(check bool) "ends with" true (ends_with "001_init.up.sql" ~suffix:".sql");
  Alcotest.(check bool) "ends with ci" true
    (ends_with_ascii_ci "Audio/MPEG" ~suffix:"audio/mpeg");
  Alcotest.(check bool) "contains ci" true
    (contains_ascii_ci "Parser Exception: bad input" "parser exception");
  Alcotest.(check bool) "contains ci miss" false
    (contains_ascii_ci "Parser Exception: bad input" "binder exception");
  Alcotest.(check bool) "token first" true
    (contains_token_ascii_ci "chunked, gzip" "chunked");
  Alcotest.(check bool) "token trims and folds" true
    (contains_token_ascii_ci "keep-alive, Upgrade" "upgrade");
  Alcotest.(check bool) "token not substring" false
    (contains_token_ascii_ci "notchunked, gzip" "chunked")

let test_string_helpers_lowercase_identity () =
  let unchanged = "audio/mpeg" in
  let lowered = Eta.String_helpers.lowercase_ascii unchanged in
  Alcotest.(check string) "unchanged contents" unchanged lowered;
  Alcotest.(check bool) "unchanged physical identity" true (lowered == unchanged);
  Alcotest.(check string) "lowered contents" "audio/mpeg"
    (Eta.String_helpers.lowercase_ascii "Audio/MPEG")

let test_string_helpers_trim_and_equal () =
  let open Eta.String_helpers in
  Alcotest.(check bool) "blank spaces" true (is_blank " \t\r\n");
  Alcotest.(check bool) "not blank" false (is_blank " x ");
  Alcotest.(check string) "trim identity" "abc" (trim "abc");
  Alcotest.(check string) "trim copy" "abc" (trim "  abc\r\n");
  Alcotest.(check bool) "trim equal" true (trim_equal "  tool " "tool");
  Alcotest.(check bool) "trim equal ci" true
    (trim_equal_ascii_ci " WebSocket\t" "websocket");
  Alcotest.(check bool) "trim equal trimmed ci" true
    (trim_equal_trimmed_ascii_ci " TraceParent " "traceparent");
  Alcotest.(check bool) "bounded token ci" true
    (trim_equal_ascii_ci_bounds "keep-alive, Upgrade" 11 19 "upgrade")

let test_string_helpers_digits () =
  let open Eta.String_helpers in
  Alcotest.(check char) "lower hex 10" 'a' (lower_hex_digit 10);
  Alcotest.(check char) "upper hex 15" 'F' (upper_hex_digit 15);
  Alcotest.(check char) "lowercase char" 'z' (lowercase_ascii_char 'Z');
  Alcotest.(check bool) "ascii ci" true (ascii_equal_ci 'A' 'a')

let tests =
  [
    ( "String_helpers",
      [
        Alcotest.test_case "prefix suffix and ascii-ci contains" `Quick
          test_string_helpers_prefix_suffix_contains;
        Alcotest.test_case "lowercase returns original when unchanged" `Quick
          test_string_helpers_lowercase_identity;
        Alcotest.test_case "trim and equality helpers" `Quick
          test_string_helpers_trim_and_equal;
        Alcotest.test_case "digit helpers" `Quick test_string_helpers_digits;
      ] );
  ]
