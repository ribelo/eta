(** Observability surface: tracing spans, attributes, events, links, contexts,
    logs, metrics, and the [named]/[fn] span wrappers. Internal: see Effect for
    the public surface. *)

open Effect_core

let with_error_renderer render effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  let frame = { frame with error_renderer = (fun err -> render (Obj.obj err)) } in
  run_to_exit frame effect

let suppress_observability effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  let runtime =
    {
      frame.runtime with
      tracing_enabled = false;
      auto_instrument = false;
      logging_enabled = false;
      metrics_enabled = false;
    }
  in
  run_to_exit { frame with runtime } effect

let named_kind ?error_renderer ~kind name effect =
  make ~leaf_name:name ~names:(name :: effect.names) @@ fun () ->
  let frame = current_frame () in
  let frame =
    match error_renderer with
    | None -> frame
    | Some render -> { frame with error_renderer = (fun err -> render (Obj.obj err)) }
  in
  try
    ok
      (Runtime_instrument.with_span ~runtime:frame.runtime
         ~error_renderer:frame.error_renderer ~fail_key:frame.fail_key ~kind
         ~name ~attrs:[] (fun () -> run_to_value frame effect))
  with exn -> exit_of_exn frame exn

let named ?error_renderer name effect =
  named_kind ?error_renderer ~kind:Capabilities.Internal name effect

let annotate ~key ~value effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  (if frame.runtime.tracing_enabled then
    match Eio.Fiber.get RObs.active_span_key with
    | Some span_id -> frame.runtime.tracer#add_attr_to ~span_id ~key ~value
    | None -> frame.runtime.tracer#add_attr ~key ~value);
  RObs.with_die_annotation key value @@ fun () -> effect.eval ()

let annotate_all attrs effect =
  List.fold_right
    (fun (key, value) acc -> annotate ~key ~value acc)
    attrs effect

let add_attrs_to_active_span frame attrs =
  if frame.runtime.tracing_enabled then
    match Eio.Fiber.get RObs.active_span_key with
    | None -> ()
    | Some span_id ->
        List.iter
          (fun (key, value) ->
            frame.runtime.tracer#add_attr_to ~span_id ~key ~value)
          attrs

let event ?(attrs = []) name =
  make @@ fun () ->
  let frame = current_frame () in
  (if frame.runtime.tracing_enabled then
     match Eio.Fiber.get RObs.active_span_key with
     | None -> ()
     | Some span_id ->
         frame.runtime.tracer#add_event ~span_id ~name
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
      ignore finalizer

let with_result_attrs ~ok_attrs ~err_attrs effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  match effect.eval () with
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

let link_span ?(attrs = []) ~trace_id ~span_id effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  let link =
    { Capabilities.link_trace_id = trace_id; link_span_id = span_id; link_attrs = attrs }
  in
  (if frame.runtime.tracing_enabled then
    match Eio.Fiber.get RObs.active_span_key with
    | Some span_id -> frame.runtime.tracer#add_link_to ~span_id link
    | None -> frame.runtime.tracer#add_link link);
  effect.eval ()

let with_context ctx effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  Eio.Fiber.with_binding RObs.trace_context_key ctx @@ fun () ->
  if frame.runtime.tracing_enabled then
    Eio.Fiber.with_binding RObs.sampled_key (Trace_context.sampled ctx) effect.eval
  else effect.eval ()

let with_external_parent ~trace_id ~span_id effect =
  match Trace_context.make ~trace_id ~span_id () with
  | Some ctx -> with_context ctx effect
  | None -> invalid_arg "Effect.with_external_parent: invalid trace context"

let current_span =
  make @@ fun () ->
  let frame = current_frame () in
  if not frame.runtime.tracing_enabled then ok None
  else
    match Eio.Fiber.get RObs.active_span_key with
    | None -> ok None
    | Some span_id -> ok (frame.runtime.tracer#inspect ~span_id)

let current_context =
  make @@ fun () ->
  let frame = current_frame () in
  if not frame.runtime.tracing_enabled then ok (Eio.Fiber.get RObs.trace_context_key)
  else
    match Eio.Fiber.get RObs.active_span_key with
    | Some span_id -> (
        match frame.runtime.tracer#inspect ~span_id with
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
        | None -> ok (Eio.Fiber.get RObs.trace_context_key))
    | None -> ok (Eio.Fiber.get RObs.trace_context_key)

let log ?(level = Capabilities.Info) ?(attrs = []) body =
  make @@ fun () ->
  let frame = current_frame () in
  (if frame.runtime.logging_enabled then
    let trace_id, span_id =
      if not frame.runtime.tracing_enabled then ("", "")
      else
        match Eio.Fiber.get RObs.active_span_key with
        | None -> ("", "")
        | Some span_id -> (
            match frame.runtime.tracer#inspect ~span_id with
            | None -> ("", "")
            | Some info -> (info.trace_id, info.span_id))
    in
    frame.runtime.logger#log
      { Capabilities.level; body; ts_ms = frame.runtime.now_ms (); attrs; trace_id; span_id });
  ok ()

let metric_update ?(description = "") ?(unit_ = "") ?(attrs = []) ~name ~kind value =
  make @@ fun () ->
  let frame = current_frame () in
  (if frame.runtime.metrics_enabled then
    frame.runtime.meter#record ~name ~description ~unit_ ~kind ~attrs ~value
      ~ts_ms:(frame.runtime.now_ms ()));
  ok ()

let metric_updates updates =
  make @@ fun () ->
  let frame = current_frame () in
  (if frame.runtime.metrics_enabled then
    let ts_ms = frame.runtime.now_ms () in
    List.iter
      (fun (name, description, unit_, kind, attrs, value) ->
        frame.runtime.meter#record ~name ~description ~unit_ ~kind ~attrs ~value ~ts_ms)
      updates);
  ok ()

let metric_updates_lazy make_updates =
  make @@ fun () ->
  let frame = current_frame () in
  if frame.runtime.metrics_enabled then (metric_updates (make_updates ())).eval () else ok ()

let here_attr (file, line, col_start, col_end) effect =
  annotate ~key:"loc"
    ~value:(Printf.sprintf "%s:%d:%d-%d" file line col_start col_end)
    effect

let fn ?(kind = Capabilities.Internal) ?error_renderer ?(attrs = []) pos name effect =
  effect |> annotate_all attrs |> here_attr pos |> named_kind ?error_renderer ~kind name
