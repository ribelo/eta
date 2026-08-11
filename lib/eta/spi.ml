(** Service-provider interface implementation: runtime-owned daemons and the
    narrow Expert extension point for runtime packages. Moved out of the
    application-facing [Effect] facade; see spi.mli for the usage contract. *)

open Effect_core

let daemon_internal eff =
  preserve ~leaf_name:"Effect.daemon" eff @@ fun frame ->
  Runtime_core.incr_active frame.runtime;
  fiber_fork_daemon frame ~sw:frame.runtime.outer_scope (fun () ->
      let _, tracer = Runtime_core.current_tracer frame.runtime in
      tracer#with_task_context frame.runtime.contract @@ fun () ->
      Fun.protect
        ~finally:(fun () -> Runtime_core.decr_active frame.runtime)
        (fun () ->
          (try
             switch_run frame @@ fun sw ->
             let finalizers = ref [] in
             (* Daemons report failures after their caller has returned, so they
                use the runtime's daemon fail key and opaque typed-failure
                renderer instead of inheriting a caller-specific renderer whose
                typed error scope may no longer be meaningful. *)
             let child_frame =
               { frame with sw; finalizers; error_renderer = default_renderer }
             in
             Runtime_core.with_finalizers ~runtime:frame.runtime
               ~fail_key:frame.runtime.default_fail_key
               ~error_renderer:child_frame.error_renderer finalizers (fun () ->
                 run_to_value child_frame eff)
           with exn ->
             Runtime_core.cause_of_exn_runtime frame.runtime
               frame.runtime.default_fail_key exn
             |> Runtime_core.emit_daemon_failure frame.runtime);
          `Stop_daemon));
  ok ()

let daemon eff =
  Effect_erasure.effect_to_public
    (daemon_internal (Runtime_erasure.effect_of_public eff))

module Expert = struct
  type context = Effect_core.frame
  type 'a intercept = 'a Runtime_observability.intercept =
    | Keep
    | Drop
    | Replace of 'a

  module Clock = struct
    type t = Capabilities.clock

    let current context = Runtime_core.current_clock context.runtime
    let same left right = left == right
    let now_ms clock = clock#now_ms ()
    let sleep clock duration = clock#sleep duration
  end

  let[@inline always] make ?leaf_name f =
    Effect_erasure.effect_to_public (Effect_core.make ?leaf_name f)
  let sync1 value run =
    Effect_erasure.effect_to_public (Effect_core.sync1 value run)
  let sync1_result value run =
    Effect_erasure.effect_to_public
      (Effect_core.Sync1_result { value; run })
  let sync1_result_bind_value value run k =
    Effect_erasure.effect_to_public
      (Effect_core.Sync1_result_bind_value
         {
           value;
           run;
           k = Runtime_erasure.effect_continuation_of_public k;
         })
  let sync1_result_bind_value_direct value run is_direct direct_run k =
    Effect_erasure.effect_to_public
      (Effect_core.Sync1_result_bind_value_direct
         {
           value;
           run;
           is_direct;
           direct_run;
           k = Runtime_erasure.effect_continuation_of_public k;
         })
  let sync1_result_map_error value run map_error =
    Effect_erasure.effect_to_public
      (Effect_core.Sync1_result_map_error { value; run; map_error })
  let map_error_seq next map_error inner =
    Effect_erasure.effect_to_public
      (Effect_core.map_error_seq
         (Runtime_erasure.effect_of_public next) map_error
         (Runtime_erasure.effect_of_public inner))
  let sync_contract2_result_map_error_sync1 next_value next_run map_error inner =
    match Runtime_erasure.effect_of_public inner with
    | Effect_core.Sync_contract2_result { value1; value2; run; _ } ->
        Effect_erasure.effect_to_public
          (Effect_core.Sync_contract2_result_map_error_sync1
             { value1; value2; run; map_error; next_value; next_run })
    | _ ->
        invalid_arg
          "Eta.Spi.Expert.sync_contract2_result_map_error_sync1: expected \
           Sync_contract2_result"
  let then_ next inner =
    Effect_erasure.effect_to_public
      (Effect_core.then_
         (Runtime_erasure.effect_of_public next)
         (Runtime_erasure.effect_of_public inner))
  let to_exit_bind_ok4_sync value1 value2 value3 value4 k inner =
    Effect_erasure.effect_to_public
      (Effect_core.to_exit_bind_ok4_sync value1 value2 value3 value4 k
         (Runtime_erasure.effect_of_public inner))
  let seq3 first second third =
    Effect_erasure.effect_to_public
      (Effect_core.seq3
         (Runtime_erasure.effect_of_public first)
         (Runtime_erasure.effect_of_public second)
         (Runtime_erasure.effect_of_public third))
  let sync4 value1 value2 value3 value4 run =
    Effect_erasure.effect_to_public
      (Effect_core.Sync4 { value1; value2; value3; value4; run })
  let effect_of_public eff = Runtime_erasure.effect_of_public eff
  let contract context = context.runtime.Runtime_core.contract
  let current_scope context = context.sw
  let outer_scope context = context.runtime.Runtime_core.outer_scope
  let runtime_service context key = Runtime_core.service context.runtime key
  let current_local key =
    make (fun context ->
        Effect_core.ok
          (context.runtime.contract.Runtime_contract.local_get key))

  let with_local key value eff =
    make (fun context ->
        context.runtime.contract.Runtime_contract.local_with_binding key value
          (fun () ->
            Effect_core.eval context (effect_of_public eff)))

  let auto_instrument context = context.runtime.Runtime_core.auto_instrument

  let instrument_leaf context ~name f =
    Runtime_instrument.instrument_leaf ~runtime:context.runtime
      ~error_renderer:context.error_renderer ~fail_key:context.fail_key ~name f

  let string_error_renderer (pp : Format.formatter -> 'err -> unit) : Obj.t -> string =
    let cache : (Obj.t * string) option ref = ref None in
    fun err ->
      match !cache with
      | Some (previous, rendered) when previous == err -> rendered
      | _ ->
          let rendered = Format.asprintf "%a" pp (Obj.obj err) in
          cache := Some (err, rendered);
          rendered

  let observability_with_error_pp context pp eff =
    let context = { context with error_renderer = string_error_renderer pp } in
    Effect_core.run_to_exit context (effect_of_public eff)

  let observability_suppress context eff =
    let runtime = context.runtime in
    if
      runtime.observability_suppressed
      || ((not runtime.capability_overrides_active)
         && not runtime.tracing_enabled
         && not runtime.auto_instrument
         && not runtime.logging_enabled
         && not runtime.metrics_enabled)
    then Effect_core.run_to_exit context (effect_of_public eff)
    else
      let runtime =
        {
          runtime with
          tracing_enabled = false;
          auto_instrument = false;
          logging_enabled = false;
          metrics_enabled = false;
          observability_suppressed = true;
        }
      in
      Effect_core.run_to_exit { context with runtime }
        (effect_of_public eff)

  let observability_with_binding context key value eff =
    let runtime =
      { context.runtime with Runtime_core.capability_overrides_active = true }
    in
    context.runtime.contract.Runtime_contract.local_with_binding key value
      (fun () -> Effect_core.eval { context with runtime } (effect_of_public eff))

  let observability_with_logger context logger eff =
    observability_with_binding context Runtime_core.logger_override logger eff

  let observability_with_tracer context tracer eff =
    let runtime =
      { context.runtime with Runtime_core.capability_overrides_active = true }
    in
    context.runtime.contract.Runtime_contract.local_with_binding
      Runtime_core.tracer_override tracer (fun () ->
        tracer#with_task_context context.runtime.contract (fun () ->
            Effect_core.eval { context with runtime } (effect_of_public eff)))

  let[@inline always] observability_named context ~kind ~error_pp name eff =
    let context =
      match error_pp with
      | None -> context
      | Some pp -> { context with error_renderer = string_error_renderer pp }
    in
    try
      Effect_core.ok
        (Runtime_instrument.with_span ~runtime:context.runtime
           ~error_renderer:context.error_renderer ~fail_key:context.fail_key ~kind
           ~name ~attrs:[] (fun () ->
             Effect_core.run_to_value context (effect_of_public eff)))
    with exn -> Effect_core.exit_of_exn context exn

  let local_get context key =
    context.runtime.contract.Runtime_contract.local_get key

  let add_attrs_to_tracer context attrs =
    let _, tracer = Runtime_core.current_tracer context.runtime in
    match local_get context Runtime_observability.active_span_key with
    | Some active ->
        List.iter
          (fun (key, value) ->
            active.Runtime_observability.tracer#add_attr_to
              context.runtime.contract ~span_id:active.span_id ~key ~value)
          attrs
    | None ->
        List.iter
          (fun (key, value) ->
            tracer#add_attr context.runtime.contract ~key ~value)
          attrs

  let[@inline always] observability_annotate context ~key ~value eff =
    let tracing_enabled, tracer = Runtime_core.current_tracer context.runtime in
    (if tracing_enabled then
       match local_get context Runtime_observability.active_span_key with
       | Some active ->
           active.Runtime_observability.tracer#add_attr_to
             context.runtime.contract ~span_id:active.span_id ~key ~value
       | None -> tracer#add_attr context.runtime.contract ~key ~value);
    Runtime_observability.with_die_annotation context.runtime.contract key value
      (fun () -> Effect_core.eval context (effect_of_public eff))

  let[@inline always] observability_annotate_all context attrs eff =
    let tracing_enabled, _ = Runtime_core.current_tracer context.runtime in
    (if tracing_enabled then add_attrs_to_tracer context attrs);
    Runtime_observability.with_die_annotations context.runtime.contract attrs
      (fun () -> Effect_core.eval context (effect_of_public eff))

  let observability_annotate_all_lazy context make_attrs eff =
    let tracing_enabled, _ = Runtime_core.current_tracer context.runtime in
    if not tracing_enabled then Effect_core.eval context (effect_of_public eff)
    else
      match make_attrs () with
      | [] -> Effect_core.eval context (effect_of_public eff)
      | attrs ->
          add_attrs_to_tracer context attrs;
          Runtime_observability.with_die_annotations context.runtime.contract
            attrs (fun () -> Effect_core.eval context (effect_of_public eff))

  let add_attrs_to_active_span context attrs =
    let tracing_enabled, _ = Runtime_core.current_tracer context.runtime in
    if tracing_enabled then
      match local_get context Runtime_observability.active_span_key with
      | None -> ()
      | Some active ->
          List.iter
            (fun (key, value) ->
              active.Runtime_observability.tracer#add_attr_to
                context.runtime.contract ~span_id:active.span_id ~key ~value)
            attrs

  let rec iter_cause_fail f = function
    | Cause.Fail err -> f err
    | Cause.Die _ | Cause.Interrupt _ -> ()
    | Cause.Sequential causes | Cause.Concurrent causes ->
        List.iter (iter_cause_fail f) causes
    | Cause.Finalizer _ -> ()
    | Cause.Suppressed { primary; finalizer } ->
        iter_cause_fail f primary;
        Stdlib.ignore finalizer

  let observability_with_result_attrs context ~ok_attrs ~err_attrs eff =
    match Effect_core.eval context (effect_of_public eff) with
    | Exit.Ok value as ok -> (
        try
          add_attrs_to_active_span context (ok_attrs value);
          ok
        with exn -> Effect_core.exit_of_exn context exn)
    | Exit.Error cause as original -> (
        try
          iter_cause_fail
            (fun err -> add_attrs_to_active_span context (err_attrs err))
            cause;
          original
        with exn ->
          let finalizer =
            Runtime_core.cause_of_exn_runtime context.runtime context.fail_key exn
          in
          Effect_core.error
            (Cause.suppressed ~primary:cause
               ~finalizer:(Effect_core.capture_finalizer_cause context finalizer)))

  let observability_link_span context ~trace_id ~span_id ~attrs eff =
    let link =
      {
        Capabilities.link_trace_id = trace_id;
        link_span_id = span_id;
        link_attrs = attrs;
      }
    in
    let tracing_enabled, tracer = Runtime_core.current_tracer context.runtime in
    (if tracing_enabled then
       match local_get context Runtime_observability.active_span_key with
       | Some active ->
           active.Runtime_observability.tracer#add_link_to
             context.runtime.contract ~span_id:active.span_id link
       | None -> tracer#add_link context.runtime.contract link);
    Effect_core.eval context (effect_of_public eff)

  let observability_with_context context trace_context eff =
    context.runtime.contract.Runtime_contract.local_with_binding
      Runtime_observability.trace_context_key trace_context (fun () ->
        let tracing_enabled, _ = Runtime_core.current_tracer context.runtime in
        if tracing_enabled then
          context.runtime.contract.Runtime_contract.local_with_binding
            Runtime_observability.sampled_key
            (Runtime_trace_context.sampled trace_context)
            (fun () -> Effect_core.eval context (effect_of_public eff))
        else Effect_core.eval context (effect_of_public eff))

  let observability_tracing_enabled context =
    fst (Runtime_core.current_tracer context.runtime)

  let first_some left right =
    match left with Some _ -> left | None -> right

  let observability_current_span context =
    let tracing_enabled, _ = Runtime_core.current_tracer context.runtime in
    if not tracing_enabled then None
    else
      match local_get context Runtime_observability.active_span_key with
      | None -> None
      | Some active ->
          let current =
            active.Runtime_observability.tracer#inspect context.runtime.contract
              ~span_id:active.span_id
          in
          first_some current active.info

  let observability_current_context context =
    let ambient () =
      local_get context Runtime_observability.trace_context_key
    in
    let tracing_enabled, _ = Runtime_core.current_tracer context.runtime in
    if not tracing_enabled then ambient ()
    else
      match local_get context Runtime_observability.active_span_key with
      | Some active -> (
          let current =
            active.Runtime_observability.tracer#inspect context.runtime.contract
              ~span_id:active.span_id
          in
          match first_some current active.info with
          | Some info ->
              Some
                {
                  Capabilities.trace_id = info.trace_id;
                  span_id = info.span_id;
                  trace_flags = info.trace_flags;
                  trace_state = info.trace_state;
                  baggage = info.baggage;
                }
          | None -> ambient ())
      | None -> ambient ()

  let observability_annotate_logs context attrs eff =
    Runtime_observability.with_log_attrs context.runtime.contract attrs (fun () ->
        Effect_core.eval context (effect_of_public eff))

  let observability_with_minimum_log_level context level eff =
    Runtime_observability.with_minimum_log_level context.runtime.contract level
      (fun () -> Effect_core.eval context (effect_of_public eff))

  let observability_intercept_log context transform eff =
    Runtime_observability.with_log_interceptor context.runtime.contract transform
      (fun () -> Effect_core.eval context (effect_of_public eff))

  let emit_log context logger level attrs body =
    let trace_id, span_id =
      let tracing_enabled, _ = Runtime_core.current_tracer context.runtime in
      if not tracing_enabled then ("", "")
      else
        match local_get context Runtime_observability.active_span_key with
        | None -> ("", "")
        | Some active -> (
            let current =
              active.Runtime_observability.tracer#inspect context.runtime.contract
                ~span_id:active.span_id
            in
            match first_some current active.info with
            | None -> ("", "")
            | Some info -> (info.trace_id, info.span_id))
    in
    let clock = Runtime_core.current_clock context.runtime in
    Runtime_observability.emit_log context.runtime.contract logger
      {
        Capabilities.level;
        body;
        ts_ms = clock#now_ms ();
        attrs =
          Runtime_observability.current_log_attrs context.runtime.contract @ attrs;
        trace_id;
        span_id;
      }

  let[@inline always] observability_log context ~level ~attrs body =
    let logging_enabled, logger = Runtime_core.current_logger context.runtime in
    if
      logging_enabled
      &&
      match
        Runtime_observability.current_minimum_log_level context.runtime.contract
      with
      | None -> true
      | Some minimum -> Runtime_observability.log_level_enabled ~minimum level
    then emit_log context logger level attrs body

  let[@inline always] observability_logf context ~level ~attrs print =
    let logging_enabled, logger = Runtime_core.current_logger context.runtime in
    if
      logging_enabled
      &&
      match
        Runtime_observability.current_minimum_log_level context.runtime.contract
      with
      | None -> true
      | Some minimum -> Runtime_observability.log_level_enabled ~minimum level
    then
      let body = Format.asprintf "%t" print in
      emit_log context logger level attrs body

  let observability_intercept_metric context transform eff =
    Runtime_observability.with_metric_interceptor context.runtime.contract
      transform (fun () -> Effect_core.eval context (effect_of_public eff))

  let[@inline always] observability_emit_metric context point =
    Runtime_observability.emit_metric context.runtime.contract
      context.runtime.meter point

  let observability_record_metrics_lazy context make_points =
    if context.runtime.metrics_enabled then
      try
        let clock = Runtime_core.current_clock context.runtime in
        let ts_ms = clock#now_ms () in
        make_points context ~ts_ms;
        Effect_core.ok ()
      with
      | exn when Runtime_core.is_cancellation context.runtime.contract exn ->
          raise exn
      | exn -> Effect_core.exit_of_exn context exn
    else Effect_core.ok ()

  let[@inline always] observability_metrics_enabled context =
    context.runtime.metrics_enabled

  let[@inline always] observability_now_ms context =
    let clock = Runtime_core.current_clock context.runtime in
    clock#now_ms ()

  let emit_trace_event context ~name ~attrs =
    let runtime = context.runtime in
    let tracing_enabled, _ = Runtime_core.current_tracer runtime in
    if tracing_enabled then
      match
        runtime.contract.Runtime_contract.local_get
          Runtime_observability.active_span_key
      with
      | None -> ()
      | Some active ->
          let clock = Runtime_core.current_clock runtime in
          active.Runtime_observability.tracer#add_event runtime.contract
            ~span_id:active.span_id ~name
            ~ts_ms:(clock#now_ms ()) ~attrs

  let[@inline always] record_metric context ~name ~description ~unit_ ~kind ~attrs
      ~value =
    let runtime = context.runtime in
    if runtime.Runtime_core.metrics_enabled then
      let clock = Runtime_core.current_clock runtime in
      Runtime_observability.emit_metric runtime.contract runtime.meter
        {
          Capabilities.name;
          description;
          unit_;
          kind;
          attrs;
          value;
          ts_ms = clock#now_ms ();
        }

  let fork_daemon context f =
    Runtime_core.incr_active context.runtime;
    context.runtime.contract.Runtime_contract.fork_daemon
      context.runtime.outer_scope (fun () ->
          let _, tracer = Runtime_core.current_tracer context.runtime in
          tracer#with_task_context context.runtime.contract @@ fun () ->
          Fun.protect
            ~finally:(fun () -> Runtime_core.decr_active context.runtime)
            f)

  let eval context eff =
    Effect_core.eval context (Runtime_erasure.effect_of_public eff)
  let eval_in_scope context sw eff =
    Effect_core.run_scope ~sw context (Runtime_erasure.effect_of_public eff)
  let exit_of_exn context exn = Effect_core.exit_of_exn context exn
end
