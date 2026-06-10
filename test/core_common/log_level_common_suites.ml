open Eta

let quick = `Quick
let log_level = Alcotest.testable Log_level.pp Log_level.equal

let test_compare_ordering () =
  let open Log_level in
  let expected = [ All; Trace; Debug; Info; Warn; Error; Fatal; Off ] in
  let rec check_pairs = function
    | [] | [ _ ] -> ()
    | a :: (b :: _ as rest) ->
        Alcotest.(check int)
          (to_string a ^ " < " ^ to_string b)
          (-1) (compare a b);
        check_pairs rest
  in
  check_pairs expected;
  Alcotest.(check int) "Fatal < Off" (-1) (compare Fatal Off);
  Alcotest.(check int) "All < Trace" (-1) (compare All Trace)

let test_equal () =
  let open Log_level in
  List.iter
    (fun level ->
      Alcotest.(check bool) "reflexive" true (equal level level))
    all;
  List.iter
    (fun a ->
      List.iter
        (fun b ->
          Alcotest.(check bool)
            ("symmetric " ^ to_string a ^ " " ^ to_string b)
            (equal a b) (equal b a))
        all)
    all;
  List.iter
    (fun a ->
      List.iter
        (fun b ->
          List.iter
            (fun c ->
              if equal a b && equal b c then
                Alcotest.(check bool)
                  ("transitive " ^ to_string a ^ " " ^ to_string b ^ " "
                 ^ to_string c)
                  true (equal a c))
            all)
        all)
    all

let test_is_enabled () =
  let open Log_level in
  Alcotest.(check bool) "at threshold" true
    (is_enabled ~at:Info ~threshold:Info);
  Alcotest.(check bool) "above threshold" true
    (is_enabled ~at:Warn ~threshold:Info);
  Alcotest.(check bool) "below threshold" false
    (is_enabled ~at:Debug ~threshold:Info);
  List.iter
    (fun level ->
      Alcotest.(check bool)
        ("off threshold at " ^ to_string level)
        false
        (is_enabled ~at:level ~threshold:Off))
    all;
  List.iter
    (fun level ->
      Alcotest.(check bool)
        ("all threshold at " ^ to_string level)
        true
        (is_enabled ~at:level ~threshold:All))
    all

let test_all_is_most_verbose () =
  let open Log_level in
  Alcotest.(check bool) "All is more verbose than Info" true
    (is_enabled ~at:All ~threshold:Info);
  Alcotest.(check bool) "All is more verbose than Trace" true
    (is_enabled ~at:All ~threshold:Trace)

let test_otel_severity () =
  let open Log_level in
  Alcotest.(check int) "info severity" 9 (to_otel_severity Info);
  Alcotest.(check bool) "round-trip 9" true
    (equal Info (of_otel_severity 9))

let test_of_otel_severity_boundaries () =
  let open Log_level in
  let cases =
    [
      (1, Trace);
      (4, Trace);
      (5, Debug);
      (8, Debug);
      (9, Info);
      (12, Info);
      (13, Warn);
      (16, Warn);
      (17, Error);
      (20, Error);
      (21, Fatal);
      (24, Fatal);
    ]
  in
  List.iter
    (fun (n, expected) ->
      Alcotest.(check bool)
        (Printf.sprintf "of_otel_severity %d" n)
        true
        (equal expected (of_otel_severity n)))
    cases

let test_of_otel_severity_out_of_range () =
  let open Log_level in
  Alcotest.(check bool) "0 -> All" true
    (equal All (of_otel_severity 0));
  Alcotest.(check bool) "100 -> Fatal" true
    (equal Fatal (of_otel_severity 100))

let test_string_roundtrip () =
  let open Log_level in
  List.iter
    (fun level ->
      match of_string (to_string level) with
      | Some actual ->
          Alcotest.(check bool)
            ("round-trip " ^ to_string level)
            true (equal level actual)
      | None -> Alcotest.fail ("round-trip failed for " ^ to_string level))
    all;
  Alcotest.(check (option log_level)) "case insensitive" (Some Info)
    (of_string "info");
  Alcotest.(check (option log_level)) "mixed case alias" (Some Off)
    (of_string "oFf");
  Alcotest.(check (option log_level)) "NONE alias" (Some Off)
    (of_string "NONE");
  Alcotest.(check (option log_level)) "OFF alias" (Some Off)
    (of_string "OFF");
  Alcotest.(check (option log_level)) "unknown returns None" None
    (of_string "unknown")

let tests =
  [
    ( "Log_level",
      [
        Alcotest.test_case "compare ordering" quick test_compare_ordering;
        Alcotest.test_case "equal reflexivity symmetry transitivity" quick
          test_equal;
        Alcotest.test_case "is_enabled" quick test_is_enabled;
        Alcotest.test_case "All is the most verbose level" quick
          test_all_is_most_verbose;
        Alcotest.test_case "otel severity roundtrip" quick test_otel_severity;
        Alcotest.test_case "otel severity boundaries" quick
          test_of_otel_severity_boundaries;
        Alcotest.test_case "otel severity out of range" quick
          test_of_otel_severity_out_of_range;
        Alcotest.test_case "string roundtrip" quick test_string_roundtrip;
      ] );
  ]
