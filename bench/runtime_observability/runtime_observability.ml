open Effet

let chain n =
  let rec go i acc =
    if i = 0 then acc
    else
      go (i - 1)
        (Effect.bind
           (fun x -> Effect.named "bench.step" (Effect.pure (x + 1)))
           acc)
  in
  go n (Effect.pure 0)

let run ?tracer ?logger ?meter ?(auto_instrument = false) program =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ?tracer ?logger ?meter
      ~auto_instrument ~env:() ()
  in
  ignore (Runtime.run rt program : (_, _) Exit.t)

let run_in_memory ?(auto_instrument = false) program =
  let tracer = Tracer.in_memory () in
  run ~tracer:(Tracer.as_capability tracer) ~auto_instrument program;
  ignore (Tracer.dump tracer)

let attrs_work n =
  let rec go i acc =
    if i = 0 then acc
    else
      go (i - 1)
        (Effect.named "bench.attrs"
           (Effect.annotate ~key:"a" ~value:"1"
              (Effect.annotate ~key:"b" ~value:"2"
                 (Effect.annotate ~key:"c" ~value:"3"
                    (Effect.annotate ~key:"d" ~value:"4"
                       (Effect.annotate ~key:"e" ~value:"5" acc))))))
  in
  go n (Effect.pure 0)

let span i : Effet_otel.Internal.span =
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

let point i : Effet.Meter.point =
  {
    name = "bench.metric";
    description = "bench";
    unit_ = "1";
    kind = Capabilities.Counter_monotonic;
    attrs = [ ("route", "/bench") ];
    value = Capabilities.Int 1;
    ts_ms = i;
  }

let run_otel kind count =
  let payload =
    match kind with
    | `Span ->
        Effet_otel.Internal.encode_traces_request
          ~resource_attrs:[ ("service.name", "bench") ] ~scope_name:"bench"
          (List.init count span)
    | `Log ->
        Effet_otel.Internal.encode_logs_request
          ~resource_attrs:[ ("service.name", "bench") ] ~scope_name:"bench"
          (List.init count log)
    | `Metric ->
        Effet_otel.Internal.encode_metrics_request
          ~resource_attrs:[ ("service.name", "bench") ] ~scope_name:"bench"
          (List.init count point)
  in
  ignore (String.length payload)

let cause_concurrent () =
  ignore (Cause.concurrent [ Cause.fail "a"; Cause.fail "b" ])

let cause_suppressed () =
  ignore (Cause.suppressed ~primary:(Cause.fail "a") ~finalizer:(Cause.fail "b"))

let trace_context_roundtrip () =
  let headers =
    [
      ("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01");
      ("tracestate", "vendorA=a:1,vendorB=b:2");
      ("baggage", "userId=42,session=abc");
    ]
  in
  match Trace_context.extract headers with
  | None -> ()
  | Some ctx -> ignore (Trace_context.inject ctx)

let repeat n f =
  for _ = 1 to n do
    f ()
  done

let workloads =
  let item name run =
    { Bench_lib.name = "effect.observability." ^ name; run; samples = None }
  in
  [
    item "noop_tracer.no_auto" (fun () -> run ~tracer:Tracer.noop (chain 10_000));
    item "noop_tracer.auto" (fun () ->
        run ~tracer:Tracer.noop ~auto_instrument:true (chain 10_000));
    item "in_memory_tracer.no_auto" (fun () -> run_in_memory (chain 10_000));
    item "in_memory_tracer.auto" (fun () ->
        run_in_memory ~auto_instrument:true (chain 10_000));
    item "named_span_only" (fun () -> run_in_memory (chain 10_000));
    item "named_with_attrs" (fun () -> run_in_memory (attrs_work 10_000));
    item "effet_otel.encoder.span.100" (fun () -> run_otel `Span 100);
    item "effet_otel.encoder.span.1000" (fun () -> run_otel `Span 1_000);
    item "effet_otel.encoder.log.100" (fun () -> run_otel `Log 100);
    item "effet_otel.encoder.metric.100" (fun () -> run_otel `Metric 100);
    item "cause.construction.fail" (fun () -> repeat 10_000 (fun () -> ignore (Cause.fail "a")));
    item "cause.construction.concurrent" (fun () -> repeat 10_000 cause_concurrent);
    item "cause.construction.suppressed" (fun () -> repeat 10_000 cause_suppressed);
    item "trace_context.extract_inject" (fun () -> repeat 10_000 trace_context_roundtrip);
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
