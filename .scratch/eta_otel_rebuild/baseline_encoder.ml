open Eta

let span i : Otel.Internal.span =
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

let point i : Eta.Meter.point =
  {
    name = "bench.metric";
    description = "bench";
    unit_ = "1";
    kind = Capabilities.Counter_monotonic;
    attrs = [ ("route", "/bench") ];
    value = Capabilities.Int 1;
    ts_ms = i;
  }

let measure f =
  Gc.compact ();
  let before = Gc.quick_stat () in
  let start = Unix.gettimeofday () in
  f ();
  let stop = Unix.gettimeofday () in
  let after = Gc.quick_stat () in
  let wall_ns = (stop -. start) *. 1_000_000_000. in
  let minor_words = after.minor_words -. before.minor_words in
  let major_words = after.major_words -. before.major_words in
  (wall_ns, minor_words, major_words)

let run_one name f =
  let wall, minor, major = measure f in
  Printf.printf "%s wall_ns %.0f minor_words %.0f major_words %.0f\n%!"
    name wall minor major

let encode_spans count () =
  Otel.Internal.encode_traces_request
    ~resource_attrs:[ ("service.name", "bench") ]
    ~scope_name:"bench" (List.init count span)
  |> String.length |> ignore

let encode_logs count () =
  Otel.Internal.encode_logs_request
    ~resource_attrs:[ ("service.name", "bench") ]
    ~scope_name:"bench" (List.init count log)
  |> String.length |> ignore

let encode_metrics count () =
  Otel.Internal.encode_metrics_request
    ~resource_attrs:[ ("service.name", "bench") ]
    ~scope_name:"bench" (List.init count point)
  |> String.length |> ignore

let () =
  run_one "span.100" (encode_spans 100);
  run_one "span.1000" (encode_spans 1_000);
  run_one "log.100" (encode_logs 100);
  run_one "metric.100" (encode_metrics 100)

