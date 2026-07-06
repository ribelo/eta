module Debug = Eta_signal_debug

let pp_counter_error formatter = function
  | `Counter_overflow name ->
      Format.fprintf formatter "Counter_overflow %S" name

let counter_error =
  Alcotest.testable pp_counter_error (fun left right -> left = right)

let test_stats_counter () =
  Alcotest.(check (result int counter_error)) "normal value" (Ok 12)
    (Debug.stats_counter ~name:"counter" 12);
  Alcotest.(check (result int counter_error)) "saturated value"
    (Error (`Counter_overflow "counter"))
    (Debug.stats_counter ~name:"counter" max_int)

let test_bool_field () =
  Alcotest.(check string) "true field" "valid=true"
    (Debug.bool_field "valid" true);
  Alcotest.(check string) "false field" "dirty=false"
    (Debug.bool_field "dirty" false)

let test_remember_latest () =
  let id (id, _value) = id in
  let entries =
    Debug.remember_latest ~max_count:3 ~id ~equal_id:Int.equal (1, "new")
      [ (2, "two"); (1, "old"); (3, "three"); (4, "four") ]
  in
  Alcotest.(check (list (pair int string)))
    "deduplicates and caps"
    [ (1, "new"); (2, "two"); (3, "three") ]
    entries;
  let empty =
    Debug.remember_latest ~max_count:0 ~id ~equal_id:Int.equal (1, "new")
      [ (2, "two") ]
  in
  Alcotest.(check (list (pair int string))) "zero cap" [] empty

let string_contains haystack needle =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec loop index =
    index + needle_length <= haystack_length
    && (String.sub haystack index needle_length = needle
       || loop (index + 1))
  in
  needle_length = 0 || loop 0

let count_occurrences haystack needle =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec loop index count =
    if index + needle_length > haystack_length then count
    else if String.sub haystack index needle_length = needle then
      loop (index + needle_length) (count + 1)
    else loop (index + 1) count
  in
  if needle_length = 0 then 0 else loop 0 0

let test_render_dot () =
  let dot =
    Debug.render_dot
      ~nodes:
        [
          {
            Debug.dot_node_id = "s1";
            dot_node_label = "kind=map signal_id=s1";
            dot_node_dependency_ids = [ "s0"; "s0"; "dead_s2" ];
          };
        ]
      ~observers:
        [
          {
            Debug.dot_observer_id = "o1";
            dot_observer_label = "observer:o1";
            dot_observed_signal_id = Some "s1";
          };
          {
            Debug.dot_observer_id = "o2";
            dot_observer_label = "observer:o2 missing_observed_signal_id=s3";
            dot_observed_signal_id = None;
          };
        ]
  in
  Alcotest.(check bool) "starts graph" true
    (string_contains dot "digraph eta_signal {");
  Alcotest.(check bool) "quotes node label" true
    (string_contains dot "s1 [label=\"kind=map signal_id=s1\"]");
  Alcotest.(check int) "deduplicates repeated dependency edges" 1
    (count_occurrences dot "s0 -> s1;");
  Alcotest.(check bool) "renders dead dependency edge" true
    (string_contains dot "dead_s2 -> s1;");
  Alcotest.(check bool) "renders observer edge" true
    (string_contains dot
       "s1 -> o1 [style=dashed,label=\"observes\"]");
  Alcotest.(check bool) "keeps missing observer diagnostic" true
    (string_contains dot "missing_observed_signal_id=s3")

let () =
  Alcotest.run "eta_signal_debug"
    [
      ( "debug",
        [
          Alcotest.test_case "stats counter" `Quick test_stats_counter;
          Alcotest.test_case "remember latest" `Quick test_remember_latest;
          Alcotest.test_case "render dot" `Quick test_render_dot;
        ] );
    ]
