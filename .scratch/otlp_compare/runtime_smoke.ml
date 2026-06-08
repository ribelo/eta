open Otlp_compare

let test_collector_ok () =
  let counts = [ (Common.Trace, 64); (Common.Log, 10); (Common.Metric, 5) ] in
  let current =
    Current_hand_roll_model.export_signals ~collector_failures:0 counts
  in
  let upstream =
    Upstream_adapter_model.export_signals ~collector_failures:0 counts
  in
  Common.assert_equal_int "current delivered" 79 current.delivered;
  Common.assert_equal_int "upstream delivered" 79 upstream.delivered;
  Common.assert_equal_int "current dropped" 0 current.dropped;
  Common.assert_equal_int "upstream dropped" 0 upstream.dropped

let test_collector_down () =
  let counts = [ (Common.Trace, 64) ] in
  let current =
    Current_hand_roll_model.export_signals ~collector_failures:10 counts
  in
  let upstream =
    Upstream_adapter_model.export_signals ~collector_failures:10 counts
  in
  Common.assert_equal_int "current attempts" 2 current.attempts;
  Common.assert_equal_int "current dropped" 64 current.dropped;
  Common.assert_equal_int "upstream attempts" 3 upstream.attempts;
  Common.assert_equal_int "upstream dropped" 64 upstream.dropped;
  Common.assert_true "upstream has retry diagnostics"
    (List.exists
       (fun msg -> String.starts_with ~prefix:"self_debug: retry" msg)
       upstream.diagnostics)

let test_intermittent_failure () =
  let counts = [ (Common.Trace, 10) ] in
  let current =
    Current_hand_roll_model.export_signals ~collector_failures:1 counts
  in
  let upstream =
    Upstream_adapter_model.export_signals ~collector_failures:1 counts
  in
  Common.assert_equal_int "current drops first failed batch" 10 current.dropped;
  Common.assert_equal_int "upstream retries then delivers" 10 upstream.delivered;
  Common.assert_equal_int "upstream no drop" 0 upstream.dropped

let test_slow_collector_pressure () =
  let counts = [ (Common.Trace, 1200) ] in
  let current =
    Current_hand_roll_model.export_under_slow_collector ~queue_capacity:500 counts
  in
  let upstream =
    Upstream_adapter_model.export_under_slow_collector ~queue_capacity:500 counts
  in
  Common.assert_equal_int "current keeps no bounded drop model" 0 current.dropped;
  Common.assert_equal_int "upstream bounded drop" 700 upstream.dropped;
  Common.assert_true "current documents blocking loop"
    (List.exists
       (fun msg -> String.starts_with ~prefix:"slow collector" msg)
       current.diagnostics);
  Common.assert_true "upstream documents queue drop"
    (List.exists
       (fun msg -> String.starts_with ~prefix:"self_debug: bounded queue full" msg)
       upstream.diagnostics)

let test_trace_context_round_trip () =
  let headers = Common.context_round_trip () in
  Common.assert_true "traceparent injected"
    (List.exists (fun (k, _) -> k = "traceparent") headers);
  Common.assert_true "tracestate injected"
    (List.exists (fun (k, _) -> k = "tracestate") headers);
  Common.assert_true "baggage injected"
    (List.exists (fun (k, _) -> k = "baggage") headers)

let () =
  test_collector_ok ();
  test_collector_down ();
  test_intermittent_failure ();
  test_slow_collector_pressure ();
  test_trace_context_round_trip ();
  print_endline "otlp_compare runtime smoke passed"
