(** Observability surface: tracing spans, attributes, events, links, contexts,
    logs, metrics, and the [named]/[fn] span wrappers. Internal: see Effect for
    the public surface. *)

open Effect_core

let local_get frame key =
  frame.runtime.contract.Runtime_contract.local_get key

let local_with_binding frame key value f =
  frame.runtime.contract.Runtime_contract.local_with_binding key value f

let with_error_renderer (render) eff =
  preserve eff @@ fun frame ->
  let frame = { frame with error_renderer = (fun err -> render (Obj.obj err)) } in
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
    }
  in
  run_to_exit { frame with runtime } eff

let named_kind ?error_renderer ~kind name eff =
  make ~leaf_name:name ~names:(name :: names eff) @@ fun frame ->
  let frame =
    match error_renderer with
    | None -> frame
    | Some render -> { frame with error_renderer = (fun err -> render (Obj.obj err)) }
  in
  try
    ok
      (Runtime_instrument.with_span ~runtime:frame.runtime
         ~error_renderer:frame.error_renderer ~fail_key:frame.fail_key ~kind
         ~name ~attrs:[] (fun () -> run_to_value frame eff))
  with exn -> exit_of_exn frame exn

let named ?error_renderer name eff =
  named_kind ?error_renderer ~kind:Capabilities.Internal name eff

let annotate ~key ~value eff =
  preserve eff @@ fun frame ->
  (if frame.runtime.tracing_enabled then
    match local_get frame RObs.active_span_key with
    | Some span_id ->
        frame.runtime.tracer#add_attr_to frame.runtime.contract ~span_id ~key
          ~value
    | None -> frame.runtime.tracer#add_attr frame.runtime.contract ~key ~value);
  RObs.with_die_annotation frame.runtime.contract key value @@ fun () ->
  eval frame eff

let annotate_all attrs eff =
  match attrs with
  | [] -> eff
  | _ ->
      preserve eff @@ fun frame ->
      (if frame.runtime.tracing_enabled then
         match local_get frame RObs.active_span_key with
         | Some span_id ->
             List.iter
               (fun (key, value) ->
                 frame.runtime.tracer#add_attr_to frame.runtime.contract
                   ~span_id ~key ~value)
               attrs
         | None ->
             List.iter
               (fun (key, value) ->
                 frame.runtime.tracer#add_attr frame.runtime.contract ~key
                   ~value)
               attrs);
      RObs.with_die_annotations frame.runtime.contract attrs @@ fun () ->
      eval frame eff

let annotate_all_lazy make_attrs eff =
  preserve eff @@ fun frame ->
  if not frame.runtime.tracing_enabled then eval frame eff
  else
    match make_attrs () with
    | [] -> eval frame eff
    | attrs ->
        (match local_get frame RObs.active_span_key with
         | Some span_id ->
             List.iter
               (fun (key, value) ->
                 frame.runtime.tracer#add_attr_to frame.runtime.contract
                   ~span_id ~key ~value)
               attrs
         | None ->
             List.iter
               (fun (key, value) ->
                 frame.runtime.tracer#add_attr frame.runtime.contract ~key
                   ~value)
               attrs);
        RObs.with_die_annotations frame.runtime.contract attrs @@ fun () ->
        eval frame eff

let add_attrs_to_active_span frame attrs =
  if frame.runtime.tracing_enabled then
    match local_get frame RObs.active_span_key with
    | None -> ()
    | Some span_id ->
        List.iter
          (fun (key, value) ->
            frame.runtime.tracer#add_attr_to frame.runtime.contract ~span_id
              ~key ~value)
          attrs

let event ?(attrs = []) name =
  make @@ fun frame ->
  (if frame.runtime.tracing_enabled then
     match local_get frame RObs.active_span_key with
     | None -> ()
     | Some span_id ->
         frame.runtime.tracer#add_event frame.runtime.contract ~span_id ~name
           ~ts_ms:(frame.runtime.now_ms ()) ~attrs);
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
  (if frame.runtime.tracing_enabled then
    match local_get frame RObs.active_span_key with
    | Some span_id ->
        frame.runtime.tracer#add_link_to frame.runtime.contract ~span_id link
    | None -> frame.runtime.tracer#add_link frame.runtime.contract link);
  eval frame eff

let with_context ctx eff =
  preserve eff @@ fun frame ->
  local_with_binding frame RObs.trace_context_key ctx @@ fun () ->
  if frame.runtime.tracing_enabled then
    local_with_binding frame RObs.sampled_key (Trace_context.sampled ctx) (fun () ->
        eval frame eff)
  else eval frame eff

let with_external_parent ~trace_id ~span_id eff =
  match Trace_context.make ~trace_id ~span_id () with
  | Some ctx -> with_context ctx eff
  | None -> invalid_arg "Effect.with_external_parent: invalid trace context"

let is_tracing_enabled = make @@ fun frame -> ok frame.runtime.tracing_enabled

let current_span =
  make @@ fun frame ->
  if not frame.runtime.tracing_enabled then ok None
  else
    match local_get frame RObs.active_span_key with
    | None -> ok None
    | Some span_id ->
        ok (frame.runtime.tracer#inspect frame.runtime.contract ~span_id)

let current_context =
  make @@ fun frame ->
  if not frame.runtime.tracing_enabled then ok (local_get frame RObs.trace_context_key)
  else
    match local_get frame RObs.active_span_key with
    | Some span_id -> (
        match frame.runtime.tracer#inspect frame.runtime.contract ~span_id with
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

let log ?(level = Capabilities.Info) ?(attrs = []) body =
  make @@ fun frame ->
  (if frame.runtime.logging_enabled then
    let trace_id, span_id =
      if not frame.runtime.tracing_enabled then ("", "")
      else
        match local_get frame RObs.active_span_key with
        | None -> ("", "")
        | Some span_id -> (
            match frame.runtime.tracer#inspect frame.runtime.contract ~span_id with
            | None -> ("", "")
            | Some info -> (info.trace_id, info.span_id))
    in
    frame.runtime.logger#log
      { Capabilities.level; body; ts_ms = frame.runtime.now_ms (); attrs; trace_id; span_id });
  ok ()

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
     record_metric frame ~ts_ms:(frame.runtime.now_ms ()) update);
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
    let ts_ms = frame.runtime.now_ms () in
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

let fn ?(kind = Capabilities.Internal) ?error_renderer ?(attrs = []) pos name eff =
  eff |> annotate_all attrs |> here_attr pos |> named_kind ?error_renderer ~kind name
