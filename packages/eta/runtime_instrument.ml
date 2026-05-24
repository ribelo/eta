open Runtime_core

let with_span ~runtime ~error_renderer ~fail_key ~kind ~name ~attrs body =
  let with_die_context f =
    RObs.with_die_span_name name @@ fun () ->
    RObs.with_die_annotations attrs f
  in
  let run_body () =
    try body () with exn ->
      raise_cause fail_key (cause_of_exn_runtime runtime fail_key exn)
  in
  if not runtime.tracing_enabled then with_die_context run_body
  else
    let parent_id = Eio.Fiber.get RObs.active_span_key in
    let ambient_context = Eio.Fiber.get RObs.trace_context_key in
    let parent_sampled =
      Option.value (Eio.Fiber.get RObs.sampled_key)
        ~default:
          (match ambient_context with
          | None -> true
          | Some ctx -> Trace_context.sampled ctx)
    in
    let external_parent =
      match parent_id with
      | Some _ -> None
      | None -> ambient_context
    in
    let sampled =
      parent_sampled
      && Sampler.sample runtime.sampler ~trace_id:"" ~name ~attrs:[]
           ~parent:(Option.is_some parent_id || Option.is_some ambient_context)
    in
    if not sampled then
      with_die_context @@ fun () ->
      Eio.Fiber.with_binding RObs.sampled_key false run_body
    else
      let started_ms = runtime.now_ms () in
      let span_id =
        runtime.tracer#begin_span ?parent_id ?external_parent ~name ~kind
          ~started_ms ()
      in
      let finish status =
        runtime.tracer#end_span ~span_id ~status ~ended_ms:(runtime.now_ms ())
      in
      let emit_exception_event cause =
        RObs.exception_event_attrs_tree ~error_renderer cause
        |> List.iter (fun attrs ->
               runtime.tracer#add_event ~span_id ~name:"exception"
                 ~ts_ms:(runtime.now_ms ()) ~attrs)
      in
      with_die_context @@ fun () ->
      Eio.Fiber.with_binding RObs.active_span_key span_id @@ fun () ->
      Eio.Fiber.with_binding RObs.sampled_key true @@ fun () ->
      try
        List.iter
          (fun (key, value) -> runtime.tracer#add_attr_to ~span_id ~key ~value)
          attrs;
        let value = body () in
        finish Ok;
        value
      with exn ->
        let cause = cause_of_exn_runtime runtime fail_key exn in
        emit_exception_event cause;
        finish (RObs.status_of_cause ~error_renderer cause);
        raise_cause fail_key cause

let interpret_named ~runtime ~error_renderer ~fail_key ~interpret_ast ~sw
    ~finalizers ~kind ~name ~attrs e =
  with_span ~runtime ~error_renderer ~fail_key ~kind ~name ~attrs (fun () ->
      interpret_ast ~runtime ~error_renderer ~fail_key ~sw ~finalizers e)

let instrument_leaf ~runtime ~error_renderer ~fail_key ~name f =
  with_span ~runtime ~error_renderer ~fail_key ~kind:Capabilities.Internal ~name
    ~attrs:[] f
