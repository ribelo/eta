open Common

let check_fixture name sink =
  let spans = spans sink in
  let logs = logs sink in
  let metrics = metrics sink in
  assert_equal_int (name ^ " span count") 1 (List.length spans);
  assert_equal_int (name ^ " log count") 1 (List.length logs);
  assert_equal_int (name ^ " metric count") 1 (List.length metrics);
  let span = List.hd spans in
  let log = List.hd logs in
  let metric = List.hd metrics in
  assert_equal_string (name ^ " log trace") span.trace_id log.trace_id;
  assert_equal_string (name ^ " log span") span.span_id log.span_id;
  assert_equal_string (name ^ " metric trace") span.trace_id metric.trace_id;
  assert_equal_string (name ^ " metric span") span.span_id metric.span_id;
  assert_equal_string (name ^ " log body") "hello" log.body;
  assert_equal_string (name ^ " metric name") "requests" metric.name

let check_adapter_drops_outside_runtime () =
  let sink = create_sink () in
  Branch_b_adapter.with_reporter (fun () ->
      Logs.info (fun m -> m "outside");
      Branch_b_adapter.Metric_registry.record ~name:"outside" ~kind:Gauge
        (Int 1));
  assert_equal_int "outside log count" 0 (List.length (logs sink));
  assert_equal_int "outside metric count" 0 (List.length (metrics sink))

let () =
  Eio_main.run @@ fun _env ->
  check_fixture "branch-a" (Branch_a_ast.fixture ());
  check_fixture "branch-b" (Branch_b_adapter.fixture ());
  check_adapter_drops_outside_runtime ();
  print_endline "log_meter_survival runtime smoke passed"

