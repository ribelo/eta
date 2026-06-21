let span i : Eta_otel.Internal.span =
  {
    trace_id = "0af7651916cd43dd8448eb211c80319c";
    span_id = Printf.sprintf "%016x" i;
    parent_span_id = None;
    trace_flags = 1;
    trace_state = [ ("vendor", "state") ];
    baggage = [];
    name = "bench.otel.span";
    kind = Eta.Capabilities.Internal;
    start_unix_ns = i;
    end_unix_ns = i + 1;
    attrs = [ ("route", "/bench"); ("method", "GET") ];
    events = [];
    links = [];
    status_code = 1;
    status_message = "";
  }

let log i : Eta.Capabilities.log_record =
  {
    ts_ms = i;
    level = Eta.Capabilities.Info;
    body = "bench log";
    attrs = [ ("route", "/bench") ];
    trace_id = "0af7651916cd43dd8448eb211c80319c";
    span_id = Printf.sprintf "%016x" i;
  }

let point i : Eta.Meter.point =
  {
    name = "bench.metric";
    description = "bench";
    unit_ = "1";
    kind = Eta.Capabilities.Counter { monotonic = true };
    attrs = [ ("route", "/bench"); ("bucket", string_of_int (i mod 10)) ];
    value = Eta.Capabilities.Number (Eta.Capabilities.Int 1);
    ts_ms = i;
  }

let run_otel kind count =
  let payload =
    match kind with
    | `Span ->
        Eta_otel.Internal.encode_traces_request
          ~resource_attrs:[ ("service.name", "bench") ] ~scope_name:"bench"
          (List.init count span)
    | `Log ->
        Eta_otel.Internal.encode_logs_request
          ~resource_attrs:[ ("service.name", "bench") ] ~scope_name:"bench"
          (List.init count log)
    | `Metric ->
        Eta_otel.Internal.encode_metrics_request
          ~resource_attrs:[ ("service.name", "bench") ] ~scope_name:"bench"
          (List.init count point)
  in
  ignore (String.length payload)

let aggregate count =
  ignore (Eta_otel.aggregate_points (List.init count point))

let workloads =
  let item name run =
    { Bench_lib.name = "otel." ^ name; run; samples = None }
  in
  [
    item "encoder.span.100" (fun () -> run_otel `Span 100);
    item "encoder.span.1000" (fun () -> run_otel `Span 1_000);
    item "encoder.log.100" (fun () -> run_otel `Log 100);
    item "encoder.metric.100" (fun () -> run_otel `Metric 100);
    item "aggregate.counter.1k" (fun () -> aggregate 1_000);
    item "aggregate.counter.10k" (fun () -> aggregate 10_000);
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
