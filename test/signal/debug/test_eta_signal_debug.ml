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
  Alcotest.(check string)
    "dot"
    "digraph eta_signal {\n\
    \  s1 [label=\"kind=map signal_id=s1\"];\n\
    \  s0 -> s1;\n\
    \  dead_s2 -> s1;\n\
    \  o1 [shape=box,label=\"observer:o1\"];\n\
    \  s1 -> o1 [style=dashed,label=\"observes\"];\n\
    \  o2 [shape=box,label=\"observer:o2 missing_observed_signal_id=s3\"];\n\
     }\n"
    dot

let () =
  Alcotest.run "eta_signal_debug"
    [
      ( "debug",
        [
          Alcotest.test_case "stats counter" `Quick test_stats_counter;
          Alcotest.test_case "bool field" `Quick test_bool_field;
          Alcotest.test_case "render dot" `Quick test_render_dot;
        ] );
    ]
