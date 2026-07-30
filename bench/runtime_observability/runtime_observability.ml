open Eta

let chain n =
  let rec go i acc =
    if i = 0 then acc
    else
      go (i - 1)
        (Effect.bind
           (fun x -> Eta_observability.named "bench.step" (Effect.pure (x + 1)))
           acc)
  in
  go n (Effect.pure 0)

let log_chain n =
  let rec go i acc =
    if i = 0 then acc
    else
      go (i - 1)
        (Effect.bind
           (fun () ->
             Eta_observability.log ~level:Capabilities.Info
               ~attrs:[ ("phase", "bench") ] "bench log")
           acc)
  in
  go n Effect.unit

let metric_chain n =
  let rec go i acc =
    if i = 0 then acc
    else
      go (i - 1)
        (Effect.bind
           (fun () ->
             Eta_observability.metric_update ~name:"bench.metric"
               ~description:"bench" ~unit_:"1"
               ~attrs:[ ("phase", "bench") ]
               ~kind:(Capabilities.Counter { monotonic = true })
               (Capabilities.Number (Capabilities.Int 1)))
           acc)
  in
  go n Effect.unit

let batch_metrics =
  List.init 4 @@ fun i ->
  Eta_observability.metric ~name:("bench.batch." ^ string_of_int i)
    ~description:"bench" ~unit_:"1" ~attrs:[ ("phase", "bench") ]
    ~kind:(Capabilities.Counter { monotonic = true })
    (Capabilities.Number (Capabilities.Int 1))

let metric_batch_chain ~lazy_ n =
  let update =
    if lazy_ then Eta_observability.metric_updates_lazy (fun () -> batch_metrics)
    else Eta_observability.metric_updates batch_metrics
  in
  let rec go i acc =
    if i = 0 then acc else go (i - 1) (Effect.bind (fun () -> update) acc)
  in
  go n Effect.unit

let run ?tracer ?logger ?meter ?(auto_instrument = false) program =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ?tracer ?logger ?meter
      ~auto_instrument ()
  in
  ignore (Runtime.run rt program : (_, _) Exit.t)

let run_in_memory ?(auto_instrument = false) program =
  let tracer = Eta_observability.Tracer.in_memory () in
  run ~tracer:(Eta_observability.Tracer.as_capability tracer) ~auto_instrument program;
  ignore (Eta_observability.Tracer.dump tracer)

let run_in_memory_logger program =
  let logger = Eta_observability.Logger.in_memory () in
  run ~logger:(Eta_observability.Logger.as_capability logger) program;
  ignore (Eta_observability.Logger.dump logger)

let run_in_memory_meter program =
  let meter = Eta_observability.Meter.in_memory () in
  run ~meter:(Eta_observability.Meter.as_capability meter) program;
  ignore (Eta_observability.Meter.dump meter)

let attrs_work n =
  let rec go i acc =
    if i = 0 then acc
    else
      go (i - 1)
        (Eta_observability.named "bench.attrs"
           (Eta_observability.annotate ~key:"a" ~value:"1"
              (Eta_observability.annotate ~key:"b" ~value:"2"
                 (Eta_observability.annotate ~key:"c" ~value:"3"
                    (Eta_observability.annotate ~key:"d" ~value:"4"
                       (Eta_observability.annotate ~key:"e" ~value:"5" acc))))))
  in
  go n (Effect.pure 0)

let span i : Eta_otel.Internal.span =
  {
    trace_id = "0af7651916cd43dd8448eb211c80319c";
    span_id = Printf.sprintf "%016x" i;
    parent_span_id = None;
    trace_flags = 1;
    trace_state = [ ("vendor", "state") ];
    baggage = [];
    name = "bench.otel.span";
    kind = Capabilities.Internal;
    start_unix_ns = i;
    end_unix_ns = i + 1;
    attrs = [ ("route", "/bench"); ("method", "GET") ];
    events = [];
    links = [];
    status_code = 1;
    status_message = "";
  }

let log i : Capabilities.log_record =
  {
    ts_ms = i;
    level = Capabilities.Info;
    body = "bench log";
    attrs = [ ("route", "/bench") ];
    trace_id = "0af7651916cd43dd8448eb211c80319c";
    span_id = Printf.sprintf "%016x" i;
  }

let point i : Eta_observability.Meter.point =
  {
    name = "bench.metric";
    description = "bench";
    unit_ = "1";
    kind = Capabilities.Counter { monotonic = true };
    attrs = [ ("route", "/bench") ];
    value = Capabilities.Number (Capabilities.Int 1);
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

let cause_concurrent () =
  ignore (Cause.concurrent [ Cause.fail "a"; Cause.fail "b" ])

let cause_suppressed () =
  ignore
    (Cause.suppressed ~primary:(Cause.fail "a")
       ~finalizer:(Cause.Finalizer.Fail { error = "b"; rendered = "b" }))

let trace_context_roundtrip () =
  let headers =
    [
      ("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01");
      ("tracestate", "vendorA=a:1,vendorB=b:2");
      ("baggage", "userId=42,session=abc");
    ]
  in
  match Eta_observability.Trace_context.extract headers with
  | None -> ()
  | Some ctx -> ignore (Eta_observability.Trace_context.inject ctx)

let workloads =
  let item name run =
    { Bench_lib.name = "effect.observability." ^ name; run; samples = None }
  in
  [
    item "noop_tracer.no_auto" (fun () -> run ~tracer:Eta_observability.Tracer.noop (chain 10_000));
    item "noop_tracer.auto" (fun () ->
        run ~tracer:Eta_observability.Tracer.noop ~auto_instrument:true (chain 10_000));
    item "in_memory_tracer.no_auto" (fun () -> run_in_memory (chain 10_000));
    item "in_memory_tracer.auto" (fun () ->
        run_in_memory ~auto_instrument:true (chain 10_000));
    item "named_span_only" (fun () -> run_in_memory (chain 10_000));
    item "named_with_attrs" (fun () -> run_in_memory (attrs_work 10_000));
    item "noop_logger.log" (fun () -> run ~logger:Eta_observability.Logger.noop (log_chain 10_000));
    item "in_memory_logger.log" (fun () ->
        run_in_memory_logger (log_chain 10_000));
    item "noop_meter.metric" (fun () -> run ~meter:Eta_observability.Meter.noop (metric_chain 10_000));
    item "in_memory_meter.metric" (fun () ->
        run_in_memory_meter (metric_chain 10_000));
    item "in_memory_meter.metric_updates.4x25000" (fun () ->
        run_in_memory_meter (metric_batch_chain ~lazy_:false 25_000));
    item "in_memory_meter.metric_updates_lazy.4x25000" (fun () ->
        run_in_memory_meter (metric_batch_chain ~lazy_:true 25_000));
    item "in_memory_meter.metric_updates_intercept_keep.4x25000" (fun () ->
        run_in_memory_meter
          (metric_batch_chain ~lazy_:false 25_000
          |> Eta_observability.intercept_metric (fun _ -> Keep)));
    item "eta_otel.encoder.span.100" (fun () -> run_otel `Span 100);
    item "eta_otel.encoder.span.1000" (fun () -> run_otel `Span 1_000);
    item "eta_otel.encoder.log.100" (fun () -> run_otel `Log 100);
    item "eta_otel.encoder.metric.100" (fun () -> run_otel `Metric 100);
    item "cause.construction.fail" (fun () ->
        Bench_lib.repeat 10_000 (fun () -> ignore (Cause.fail "a")));
    item "cause.construction.concurrent" (fun () ->
        Bench_lib.repeat 10_000 cause_concurrent);
    item "cause.construction.suppressed" (fun () ->
        Bench_lib.repeat 10_000 cause_suppressed);
    item "trace_context.extract_inject" (fun () ->
        Bench_lib.repeat 10_000 trace_context_roundtrip);
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
