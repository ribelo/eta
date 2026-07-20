(** Observability surface: tracing spans, attributes, events, links, contexts,
    logs, metrics, and the [named]/[fn] span wrappers. Internal: see Effect for
    the public surface. *)

open Effect_core

let local_get frame key =
  frame.runtime.contract.Runtime_contract.local_get key

let local_with_binding frame key value f =
  frame.runtime.contract.Runtime_contract.local_with_binding key value f

let first_some left right =
  match left with Some _ -> left | None -> right

let string_error_renderer (pp : Format.formatter -> 'err -> unit) : Obj.t -> string =
  (* Memoize by physical identity so span status and exception-event paths share
     one render for the same typed failure. *)
  let cache : (Obj.t * string) option ref = ref None in
  fun err ->
    match !cache with
    | Some (prev, rendered) when prev == err -> rendered
    | _ ->
        let rendered = Format.asprintf "%a" pp (Obj.obj err) in
        cache := Some (err, rendered);
        rendered

let with_error_pp (pp : Format.formatter -> 'err -> unit) eff =
  preserve eff @@ fun frame ->
  let frame = { frame with error_renderer = string_error_renderer pp } in
  run_to_exit frame eff

let suppress_observability eff =
  preserve eff @@ fun frame ->
  let runtime =
    {
      frame.runtime with
      tracing_enabled = false;
      auto_instrument = false;
      logging_enabled = false;
      metrics_enabled = false;
      observability_suppressed = true;
    }
  in
  run_to_exit { frame with runtime } eff

let with_runtime_binding key value eff =
  preserve eff @@ fun frame ->
  local_with_binding frame key value @@ fun () -> eval frame eff

let with_clock clock eff =
  with_runtime_binding Runtime_core.clock_override clock eff

let with_random random eff =
  with_runtime_binding Runtime_core.random_override random eff

let with_logger logger eff =
  with_runtime_binding Runtime_core.logger_override logger eff

let with_tracer tracer eff =
  preserve eff @@ fun frame ->
  local_with_binding frame Runtime_core.tracer_override tracer @@ fun () ->
  tracer#with_task_context frame.runtime.contract @@ fun () -> eval frame eff

let named ?(kind = Capabilities.Internal) ?error_pp name eff =
  make ~leaf_name:name ~names:(name :: names eff) @@ fun frame ->
  let frame =
    match error_pp with
    | None -> frame
    | Some pp -> { frame with error_renderer = string_error_renderer pp }
  in
  try
    ok
      (Runtime_instrument.with_span ~runtime:frame.runtime
         ~error_renderer:frame.error_renderer ~fail_key:frame.fail_key ~kind
         ~name ~attrs:[] (fun () -> run_to_value frame eff))
  with exn -> exit_of_exn frame exn

let annotate ~key ~value eff =
  preserve eff @@ fun frame ->
  let tracing_enabled, tracer = Runtime_core.current_tracer frame.runtime in
  (if tracing_enabled then
    match local_get frame RObs.active_span_key with
    | Some active ->
        active.RObs.tracer#add_attr_to frame.runtime.contract
          ~span_id:active.span_id ~key ~value
    | None -> tracer#add_attr frame.runtime.contract ~key ~value);
  RObs.with_die_annotation frame.runtime.contract key value @@ fun () ->
  eval frame eff

let[@inline always] add_attrs_to_tracer frame attrs =
  let _, tracer = Runtime_core.current_tracer frame.runtime in
  match local_get frame RObs.active_span_key with
  | Some active ->
      List.iter
        (fun (key, value) ->
          active.RObs.tracer#add_attr_to frame.runtime.contract
            ~span_id:active.span_id ~key ~value)
        attrs
  | None ->
      List.iter
        (fun (key, value) ->
          tracer#add_attr frame.runtime.contract ~key ~value)
        attrs

let annotate_all attrs eff =
  match attrs with
  | [] -> eff
  | _ ->
      preserve eff @@ fun frame ->
      let tracing_enabled, _ = Runtime_core.current_tracer frame.runtime in
      (if tracing_enabled then add_attrs_to_tracer frame attrs);
      RObs.with_die_annotations frame.runtime.contract attrs @@ fun () ->
      eval frame eff

let annotate_all_lazy make_attrs eff =
  preserve eff @@ fun frame ->
  let tracing_enabled, _ = Runtime_core.current_tracer frame.runtime in
  if not tracing_enabled then eval frame eff
  else
    match make_attrs () with
    | [] -> eval frame eff
    | attrs ->
        add_attrs_to_tracer frame attrs;
        RObs.with_die_annotations frame.runtime.contract attrs @@ fun () ->
        eval frame eff

let add_attrs_to_active_span frame attrs =
  let tracing_enabled, _ = Runtime_core.current_tracer frame.runtime in
  if tracing_enabled then
    match local_get frame RObs.active_span_key with
    | None -> ()
    | Some active ->
        List.iter
          (fun (key, value) ->
            active.RObs.tracer#add_attr_to frame.runtime.contract
              ~span_id:active.span_id ~key ~value)
          attrs

let event ?(attrs = []) name =
  make @@ fun frame ->
  let tracing_enabled, _ = Runtime_core.current_tracer frame.runtime in
  (if tracing_enabled then
     match local_get frame RObs.active_span_key with
     | None -> ()
     | Some active ->
         let clock = Runtime_core.current_clock frame.runtime in
         active.RObs.tracer#add_event frame.runtime.contract
           ~span_id:active.span_id ~name
           ~ts_ms:(clock#now_ms ()) ~attrs);
  ok ()

let rec iter_cause_fail f = function
  | Cause.Fail err -> f err
  | Cause.Die _ | Cause.Interrupt _ -> ()
  | Cause.Sequential causes | Cause.Concurrent causes ->
      List.iter (iter_cause_fail f) causes
  | Cause.Finalizer _ -> ()
  | Cause.Suppressed { primary; finalizer } ->
      iter_cause_fail f primary;
      Stdlib.ignore finalizer

let with_result_attrs ~(ok_attrs) ~(err_attrs) eff =
  preserve eff @@ fun frame ->
  match eval frame eff with
  | Exit.Ok value as ok -> (
      try
        add_attrs_to_active_span frame (ok_attrs value);
        ok
      with exn -> exit_of_exn frame exn)
  | Exit.Error cause as original -> (
      try
        iter_cause_fail
          (fun err -> add_attrs_to_active_span frame (err_attrs err))
          cause;
        original
      with exn ->
        let finalizer =
          Runtime_core.cause_of_exn_runtime frame.runtime frame.fail_key exn
        in
        error
          (Cause.suppressed ~primary:cause
             ~finalizer:(render_cause_error frame finalizer)))

let link_span ?(attrs = []) ~trace_id ~span_id eff =
  preserve eff @@ fun frame ->
  let link =
    { Capabilities.link_trace_id = trace_id; link_span_id = span_id; link_attrs = attrs }
  in
  let tracing_enabled, tracer = Runtime_core.current_tracer frame.runtime in
  (if tracing_enabled then
    match local_get frame RObs.active_span_key with
    | Some active ->
        active.RObs.tracer#add_link_to frame.runtime.contract
          ~span_id:active.span_id link
    | None -> tracer#add_link frame.runtime.contract link);
  eval frame eff

let with_context ctx eff =
  preserve eff @@ fun frame ->
  local_with_binding frame RObs.trace_context_key ctx @@ fun () ->
  let tracing_enabled, _ = Runtime_core.current_tracer frame.runtime in
  if tracing_enabled then
    local_with_binding frame RObs.sampled_key (Trace_context.sampled ctx) (fun () ->
        eval frame eff)
  else eval frame eff

let with_external_parent ~trace_id ~span_id eff =
  match Trace_context.make ~trace_id ~span_id () with
  | Some ctx -> with_context ctx eff
  | None -> invalid_arg "Effect.with_external_parent: invalid trace context"

let is_tracing_enabled =
  make @@ fun frame ->
  let tracing_enabled, _ = Runtime_core.current_tracer frame.runtime in
  ok tracing_enabled

let current_span =
  make @@ fun frame ->
  let tracing_enabled, _ = Runtime_core.current_tracer frame.runtime in
  if not tracing_enabled then ok None
  else
    match local_get frame RObs.active_span_key with
    | None -> ok None
    | Some active ->
        let current =
          active.RObs.tracer#inspect frame.runtime.contract
            ~span_id:active.span_id
        in
        ok (first_some current active.info)

let current_context =
  make @@ fun frame ->
  let tracing_enabled, _ = Runtime_core.current_tracer frame.runtime in
  if not tracing_enabled then ok (local_get frame RObs.trace_context_key)
  else
    match local_get frame RObs.active_span_key with
    | Some active -> (
        let current =
          active.RObs.tracer#inspect frame.runtime.contract
            ~span_id:active.span_id
        in
        match first_some current active.info with
        | Some info ->
            ok
              (Some
                 {
                   Capabilities.trace_id = info.trace_id;
                   span_id = info.span_id;
                   trace_flags = info.trace_flags;
                   trace_state = info.trace_state;
                   baggage = info.baggage;
                 })
        | None -> ok (local_get frame RObs.trace_context_key))
    | None -> ok (local_get frame RObs.trace_context_key)

let annotate_logs attrs eff =
  match attrs with
  | [] -> eff
  | _ ->
      preserve eff @@ fun frame ->
      RObs.with_log_attrs frame.runtime.contract attrs @@ fun () ->
      eval frame eff

let with_minimum_log_level level eff =
  preserve eff @@ fun frame ->
  RObs.with_minimum_log_level frame.runtime.contract level @@ fun () ->
  eval frame eff

let log ?(level = Capabilities.Info) ?(attrs = []) body =
  make @@ fun frame ->
  let logging_enabled, logger = Runtime_core.current_logger frame.runtime in
  (if
     logging_enabled
     &&
     match RObs.current_minimum_log_level frame.runtime.contract with
     | None -> true
     | Some minimum -> RObs.log_level_enabled ~minimum level
   then
    let scoped_attrs = RObs.current_log_attrs frame.runtime.contract in
    let trace_id, span_id =
      let tracing_enabled, _ = Runtime_core.current_tracer frame.runtime in
      if not tracing_enabled then ("", "")
      else
        match local_get frame RObs.active_span_key with
        | None -> ("", "")
        | Some active -> (
            let current =
              active.RObs.tracer#inspect frame.runtime.contract
                ~span_id:active.span_id
            in
            match first_some current active.info with
            | None -> ("", "")
            | Some info -> (info.trace_id, info.span_id))
    in
    let clock = Runtime_core.current_clock frame.runtime in
    logger#log
      {
        Capabilities.level;
        body;
        ts_ms = clock#now_ms ();
        attrs = scoped_attrs @ attrs;
        trace_id;
        span_id;
      });
  ok ()

let log_trace ?attrs body = log ~level:Capabilities.Trace ?attrs body
let log_debug ?attrs body = log ~level:Capabilities.Debug ?attrs body
let log_info ?attrs body = log ~level:Capabilities.Info ?attrs body
let log_warn ?attrs body = log ~level:Capabilities.Warn ?attrs body
let log_error ?attrs body = log ~level:Capabilities.Error ?attrs body
let log_fatal ?attrs body = log ~level:Capabilities.Fatal ?attrs body

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

let record_metric frame ~ts_ms { name; description; unit_; attrs; kind; value } =
  frame.runtime.meter#record
    { name; description; unit_; attrs; kind; value; ts_ms }

let metric_update ?description ?unit_ ?attrs ~name ~kind value =
  make @@ fun frame ->
  (if frame.runtime.metrics_enabled then
     let update = metric ?description ?unit_ ?attrs ~name ~kind value in
     let clock = Runtime_core.current_clock frame.runtime in
     record_metric frame ~ts_ms:(clock#now_ms ()) update);
  ok ()

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

let metric_summary ?description ?unit_ ?attrs ~name ~quantiles ~max_age
    ~max_size value =
  metric_update ?description ?unit_ ?attrs ~name
    ~kind:(Meter.summary ~quantiles ~max_age ~max_size)
    (Capabilities.Number (Capabilities.Float value))

let metric_updates updates =
  make @@ fun frame ->
  (if frame.runtime.metrics_enabled then
    let clock = Runtime_core.current_clock frame.runtime in
    let ts_ms = clock#now_ms () in
    List.iter (record_metric frame ~ts_ms) updates);
  ok ()

let metric_updates_lazy make_updates =
  make @@ fun frame ->
  if frame.runtime.metrics_enabled then
    try eval frame (metric_updates (make_updates ())) with
    | exn when Runtime_core.is_cancellation frame.runtime.contract exn ->
        raise exn
    | exn -> exit_of_exn frame exn
  else ok ()

let here_attr (file, line, col_start, col_end) eff =
  annotate ~key:"loc"
    ~value:(Printf.sprintf "%s:%d:%d-%d" file line col_start col_end)
    eff

let fn ?(kind = Capabilities.Internal) ?error_pp ?(attrs = []) pos name eff =
  eff |> annotate_all attrs |> here_attr pos |> named ~kind ?error_pp name
