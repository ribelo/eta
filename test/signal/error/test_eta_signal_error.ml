module Error = Eta_signal_error

type observer_error = Observer_failed

let pp_observer_error ppf Observer_failed =
  Format.pp_print_string ppf "observer failed"

let render pp value = Format.asprintf "%a" pp value

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
        ] );
    ]
