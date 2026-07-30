open Eta

module Log_level = Log_level
module Logger = Logger
module Meter = Meter
module Tracer = Tracer
module Trace_context = Trace_context

module Expert = Spi.Expert

let with_error_pp pp eff =
  Expert.make (fun context ->
      Expert.observability_with_error_pp context pp eff)

let suppress_observability eff =
  Expert.make (fun context -> Expert.observability_suppress context eff)

let with_logger logger eff =
  Expert.make (fun context ->
      Expert.observability_with_logger context logger eff)

let with_tracer tracer eff =
  Expert.make (fun context ->
      Expert.observability_with_tracer context tracer eff)

let named ?(kind = Capabilities.Internal) ?error_pp name eff =
  Expert.make ~leaf_name:name (fun context ->
      Expert.observability_named context ~kind ~error_pp name eff)

let annotate ~key ~value eff =
  Expert.make (fun context ->
      Expert.observability_annotate context ~key ~value eff)

let annotate_all attrs eff =
  match attrs with
  | [] -> eff
  | _ ->
      Expert.make (fun context ->
          Expert.observability_annotate_all context attrs eff)

let annotate_all_lazy make_attrs eff =
  Expert.make (fun context ->
      Expert.observability_annotate_all_lazy context make_attrs eff)

let is_tracing_enabled =
  Expert.make ~leaf_name:"Effect.is_tracing_enabled" (fun context ->
      Exit.Ok (Expert.observability_tracing_enabled context))

let event ?(attrs = []) name =
  Expert.make ~leaf_name:"Effect.event" (fun context ->
      Expert.emit_trace_event context ~name ~attrs;
      Exit.Ok ())

let with_result_attrs ~ok_attrs ~err_attrs eff =
  Expert.make (fun context ->
      Expert.observability_with_result_attrs context ~ok_attrs ~err_attrs eff)

let link_span ?(attrs = []) ~trace_id ~span_id eff =
  Expert.make (fun context ->
      Expert.observability_link_span context ~trace_id ~span_id ~attrs eff)

let with_context trace_context eff =
  Expert.make (fun context ->
      Expert.observability_with_context context trace_context eff)

let with_external_parent ~trace_id ~span_id eff =
  match Trace_context.make ~trace_id ~span_id () with
  | Some context -> with_context context eff
  | None -> invalid_arg "Effect.with_external_parent: invalid trace context"

let current_span =
  Expert.make ~leaf_name:"Effect.current_span" (fun context ->
      Exit.Ok (Expert.observability_current_span context))

let current_context =
  Expert.make ~leaf_name:"Effect.current_context" (fun context ->
      Exit.Ok (Expert.observability_current_context context))

let annotate_logs attrs eff =
  match attrs with
  | [] -> eff
  | _ ->
      Expert.make (fun context ->
          Expert.observability_annotate_logs context attrs eff)

let with_minimum_log_level level eff =
  Expert.make (fun context ->
      Expert.observability_with_minimum_log_level context level eff)

type 'a intercept = 'a Expert.intercept = Keep | Drop | Replace of 'a

let intercept_log transform eff =
  Expert.make (fun context ->
      Expert.observability_intercept_log context transform eff)

let log ?(level = Capabilities.Info) ?(attrs = []) body =
  Expert.make ~leaf_name:"Effect.log" (fun context ->
      Expert.observability_log context ~level ~attrs body;
      Exit.Ok ())

let logf ?(level = Capabilities.Info) ?(attrs = []) print =
  Expert.make ~leaf_name:"Effect.logf" (fun context ->
      Expert.observability_logf context ~level ~attrs print;
      Exit.Ok ())

let log_trace ?attrs body = log ~level:Capabilities.Trace ?attrs body
let log_debug ?attrs body = log ~level:Capabilities.Debug ?attrs body
let log_info ?attrs body = log ~level:Capabilities.Info ?attrs body
let log_warn ?attrs body = log ~level:Capabilities.Warn ?attrs body
let log_error ?attrs body = log ~level:Capabilities.Error ?attrs body
let log_fatal ?attrs body = log ~level:Capabilities.Fatal ?attrs body

let intercept_metric transform eff =
  Expert.make (fun context ->
      Expert.observability_intercept_metric context transform eff)

type metric = {
  name : string;
  description : string;
  unit_ : string;
  attrs : (string * string) list;
  kind : Capabilities.metric_kind;
  value : Capabilities.metric_value;
}

let metric ?(description = "") ?(unit_ = "") ?(attrs = []) ~name ~kind value =
  { name; description; unit_; attrs; kind; value }

let point_of_metric metric =
  {
    Capabilities.name = metric.name;
    description = metric.description;
    unit_ = metric.unit_;
    kind = metric.kind;
    attrs = metric.attrs;
    value = metric.value;
    ts_ms = 0;
  }

let metric_update ?(description = "") ?(unit_ = "") ?(attrs = []) ~name ~kind
    value =
  Expert.make ~leaf_name:"Effect.metric_update" (fun context ->
      Expert.record_metric context ~name ~description ~unit_ ~kind ~attrs ~value;
      Exit.Ok ())

let metric_counter ?description ?unit_ ?attrs ~name ?(monotonic = false) value =
  metric_update ?description ?unit_ ?attrs ~name
    ~kind:(Capabilities.Counter { monotonic })
    (Capabilities.Number value)

let metric_gauge ?description ?unit_ ?attrs ~name value =
  metric_update ?description ?unit_ ?attrs ~name ~kind:Capabilities.Gauge
    (Capabilities.Number value)

let metric_frequency ?description ?unit_ ?attrs ~name category =
  metric_update ?description ?unit_ ?attrs ~name ~kind:Capabilities.Frequency
    (Capabilities.Category category)

let metric_histogram ?description ?unit_ ?attrs ~name ~boundaries value =
  metric_update ?description ?unit_ ?attrs ~name
    ~kind:(Meter.histogram ~boundaries)
    (Capabilities.Number (Capabilities.Float value))

let metric_summary ?description ?unit_ ?attrs ~name ~quantiles ~max_age ~max_size
    value =
  metric_update ?description ?unit_ ?attrs ~name
    ~kind:(Meter.summary ~quantiles ~max_age ~max_size)
    (Capabilities.Number (Capabilities.Float value))

let metric_updates metrics =
  let make_points () = List.map point_of_metric metrics in
  Expert.make ~leaf_name:"Effect.metric_updates" (fun context ->
      Expert.observability_record_metrics_lazy context make_points)

let metric_updates_lazy make_metrics =
  let make_points () = List.map point_of_metric (make_metrics ()) in
  Expert.make ~leaf_name:"Effect.metric_updates_lazy" (fun context ->
      Expert.observability_record_metrics_lazy context make_points)

let metric_timer ?description ?(unit_ = "ms") ?attrs ~name ~boundaries eff =
  let timer =
    Effect.now_ms
    |> Effect.bind (fun started ->
           Effect.on_exit
             (fun _exit ->
               Effect.now_ms
               |> Effect.bind (fun ended ->
                      let elapsed_ms = max 0 (ended - started) in
                      metric_histogram ?description ~unit_ ?attrs ~name
                        ~boundaries (float_of_int elapsed_ms)))
             eff)
  in
  Expert.make ~leaf_name:"Effect.metric_timer" (fun context ->
      Expert.eval context timer)

let here_attr (file, line, col_start, col_end) eff =
  annotate ~key:"loc"
    ~value:(Printf.sprintf "%s:%d:%d-%d" file line col_start col_end)
    eff

let fn ?(kind = Capabilities.Internal) ?error_pp ?(attrs = []) pos name eff =
  eff |> annotate_all attrs |> here_attr pos |> named ~kind ?error_pp name
