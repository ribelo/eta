module Error = Eta_signal_error

type observer_error = Observer_failed

exception Graph_failure of Error.graph_error
exception Plain_failure

let pp_observer_error ppf Observer_failed =
  Format.pp_print_string ppf "observer failed"

let render pp value = Format.asprintf "%a" pp value

let graph_error_of_die die =
  match die.Eta.Cause.exn with
  | Graph_failure err -> Some err
  | _ -> None

let pp_hidden_cause ppf _ =
  Format.pp_print_string ppf "<signal stabilize error>"

let assert_stabilize_cause label expected actual =
  if
    not
      (Eta.Cause.equal
         (fun left right ->
           match (left, right) with
           | `Observer_error Observer_failed, `Observer_error Observer_failed ->
               true
           | (#Error.graph_error as left), (#Error.graph_error as right) ->
               left = right
           | _ -> false)
         expected actual)
  then
    Alcotest.failf "%s: expected %a, got %a" label
      (Eta.Cause.pp pp_hidden_cause)
      expected
      (Eta.Cause.pp pp_hidden_cause)
      actual

let test_graph_error_rendering () =
  Alcotest.(check string) "ambiguous scope" "ambiguous dynamic scope"
    (render Error.pp_graph_error `Ambiguous_scope);
  Alcotest.(check string) "counter overflow"
    "internal counter overflow: node id"
    (render Error.pp_graph_error (`Counter_overflow "node id"));
  Alcotest.(check string) "cycle" "cycle detected"
    (render Error.pp_graph_error `Cycle);
  Alcotest.(check string) "runtime mismatch"
    "timer used from a different Eta runtime"
    (render Error.pp_graph_error `Runtime_mismatch)

let test_observer_read_error_rendering () =
  Alcotest.(check string) "disposed" "disposed observer"
    (render Error.pp_observer_read_error `Disposed_observer);
  Alcotest.(check string) "uninitialized" "uninitialized observer"
    (render Error.pp_observer_read_error `Uninitialized_observer)

let test_stabilize_error_rendering () =
  Alcotest.(check string) "graph" "cycle detected"
    (render (Error.pp_stabilize_error pp_observer_error) `Cycle);
  Alcotest.(check string) "observer" "observer callback failed: observer failed"
    (render
       (Error.pp_stabilize_error pp_observer_error)
       (`Observer_error Observer_failed))

let test_time_and_stream_error_rendering () =
  Alcotest.(check string) "deadline overflow" "deadline arithmetic overflow"
    (render Error.pp_time_error `Deadline_overflow);
  Alcotest.(check string) "invalid interval" "invalid interval"
    (render Error.pp_time_error `Invalid_interval);
  Alcotest.(check string) "invalid capacity"
    "stream bridge capacity must be positive"
    (render Error.pp_stream_error `Invalid_capacity)

let test_observer_cause_maps_typed_failures () =
  let actual =
    Error.observer_cause_to_stabilize ~graph_error_of_die
      (Eta.Cause.Fail Observer_failed)
  in
  assert_stabilize_cause "typed observer failure"
    (Eta.Cause.Fail (`Observer_error Observer_failed))
    actual

let test_observer_cause_recovers_graph_failures_from_defects () =
  let actual =
    Error.observer_cause_to_stabilize ~graph_error_of_die
      (Eta.Cause.die (Graph_failure `Runtime_mismatch))
  in
  assert_stabilize_cause "graph defect" (Eta.Cause.Fail `Runtime_mismatch)
    actual

let test_observer_cause_preserves_unclassified_defects () =
  let defect = Plain_failure in
  match
    Error.observer_cause_to_stabilize ~graph_error_of_die
      (Eta.Cause.die defect)
  with
  | Eta.Cause.Die die when die.Eta.Cause.exn == defect -> ()
  | cause ->
      Alcotest.failf "expected preserved defect, got %a"
        (Eta.Cause.pp pp_hidden_cause)
        cause

let test_observer_cause_maps_nested_primary_only () =
  let interrupt_id = Eta.Cause.fresh_interrupt_id () in
  let finalizer = Eta.Cause.Finalizer.Fail "cleanup failed" in
  let source =
    Eta.Cause.Suppressed
      {
        primary =
          Eta.Cause.Concurrent
            [
              Eta.Cause.Fail Observer_failed;
              Eta.Cause.Interrupt (Some interrupt_id);
              Eta.Cause.die (Graph_failure `Cycle);
            ];
        finalizer;
      }
  in
  let actual =
    Error.observer_cause_to_stabilize ~graph_error_of_die source
  in
  let expected =
    Eta.Cause.Suppressed
      {
        primary =
          Eta.Cause.Concurrent
            [
              Eta.Cause.Fail (`Observer_error Observer_failed);
              Eta.Cause.Interrupt (Some interrupt_id);
              Eta.Cause.Fail `Cycle;
            ];
        finalizer;
      }
  in
  assert_stabilize_cause "nested primary cause" expected actual

let () =
  Alcotest.run "eta_signal_error"
    [
      ( "error",
        [
          Alcotest.test_case "graph rendering" `Quick test_graph_error_rendering;
          Alcotest.test_case "observer read rendering" `Quick
            test_observer_read_error_rendering;
          Alcotest.test_case "stabilize rendering" `Quick
            test_stabilize_error_rendering;
          Alcotest.test_case "time and stream rendering" `Quick
            test_time_and_stream_error_rendering;
          Alcotest.test_case "observer cause maps typed failures" `Quick
            test_observer_cause_maps_typed_failures;
          Alcotest.test_case "observer cause recovers graph failures" `Quick
            test_observer_cause_recovers_graph_failures_from_defects;
          Alcotest.test_case "observer cause preserves other defects" `Quick
            test_observer_cause_preserves_unclassified_defects;
          Alcotest.test_case "observer cause maps nested primary only" `Quick
            test_observer_cause_maps_nested_primary_only;
        ] );
    ]
