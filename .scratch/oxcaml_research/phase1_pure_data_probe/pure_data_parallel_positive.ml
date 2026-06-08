open! Portable

type payload : immutable_data = {
  duration : Effet.Duration.t;
  schedule : Effet.Schedule.t;
  context : Effet.Trace_context.t;
  sampler : Effet.Sampler.t;
  span_info : Effet.Capabilities.span_info;
  link : Effet.Capabilities.span_link;
  log_record : Effet.Logger.record;
  meter_point : Effet.Meter.point;
  tracer_event : Effet.Tracer.event;
  tracer_span : Effet.Tracer.span;
}

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let context =
  match
    Effet.Trace_context.make
      ~trace_id:"4bf92f3577b34da6a3ce929d0e0e4736"
      ~span_id:"00f067aa0ba902b7" ~trace_state:[ ("rojo", "00") ]
      ~baggage:[ ("tenant", "alpha") ] ()
  with
  | Some ctx -> ctx
  | None -> failwith "bad fixture context"

let duration = Effet.Duration.seconds 2

let schedule =
  Effet.Schedule.both (Effet.Schedule.recurs 3)
    (Effet.Schedule.spaced duration)

let sampler = Effet.Sampler.parent_based ~root:(Effet.Sampler.ratio 0.5) ()

let span_info : Effet.Capabilities.span_info =
  {
    trace_id = context.trace_id;
    span_id = context.span_id;
    name = "root";
    trace_flags = context.trace_flags;
    trace_state = context.trace_state;
    baggage = context.baggage;
  }

let link : Effet.Capabilities.span_link =
  {
    link_trace_id = context.trace_id;
    link_span_id = context.span_id;
    link_attrs = [ ("kind", "follows_from") ];
  }

let log_record : Effet.Logger.record =
  {
    level = Info;
    body = "hello";
    ts_ms = 1;
    attrs = [ ("component", "phase1") ];
    trace_id = context.trace_id;
    span_id = context.span_id;
  }

let meter_point : Effet.Meter.point =
  {
    name = "requests";
    description = "request count";
    unit_ = "1";
    kind = Counter_monotonic;
    attrs = [ ("route", "/") ];
    value = Int 1;
    ts_ms = 2;
  }

let tracer_event : Effet.Tracer.event =
  { ev_name = "exception"; ev_ts_ms = 3; ev_attrs = [ ("escaped", "false") ] }

let tracer_span : Effet.Tracer.span =
  {
    span_id = 1;
    parent_id = None;
    name = "root";
    attrs = [ ("component", "phase1") ];
    events = [ tracer_event ];
    links = [ link ];
    kind = Internal;
    status = Ok;
    started_ms = 1;
    ended_ms = 2;
    trace_id = context.trace_id;
    trace_flags = context.trace_flags;
    trace_state = context.trace_state;
    baggage = context.baggage;
    external_parent = Some context;
  }

let payload =
  {
    duration;
    schedule;
    context;
    sampler;
    span_info;
    link;
    log_record;
    meter_point;
    tracer_event;
    tracer_span;
  }

let () =
  let result =
    with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        let #(left, right) =
          Parallel.fork_join2 parallel (fun _ -> payload) (fun _ -> payload)
        in
        (left, right)))
  in
  match result with
  | left, _ ->
      if Effet.Duration.to_ms left.duration <> 2_000 then
        failwith "duration did not cross domain";
      if left.context.trace_id <> left.tracer_span.trace_id then
        failwith "trace context did not cross domain";
      if left.log_record.body <> "hello" then failwith "log record changed";
      if left.meter_point.name <> "requests" then failwith "meter point changed";
      if
        not
          (Effet.Sampler.sample left.sampler ~trace_id:"abc" ~name:"root"
             ~attrs:[] ~parent:true)
      then failwith "sampler policy changed"
