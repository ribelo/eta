(** Public Effect implementation. *)

open Effect_core

include Effect_core
include Effect_resource
include Effect_concurrent
include Effect_observability
include Effect_supervisor_scope
include Effect_schedule

let metric_timer ?description ?(unit_ = "ms") ?attrs ~name ~boundaries eff =
  let timer =
    now_ms
    |> bind (fun started ->
           on_exit
             (fun _exit ->
               now_ms
               |> bind (fun ended ->
                      let elapsed_ms = max 0 (ended - started) in
                      metric_histogram ?description ~unit_ ?attrs ~name
                        ~boundaries (float_of_int elapsed_ms)))
             eff)
  in
  preserve ~leaf_name:"Effect.metric_timer"
    ~footprint:(footprint ~uses_clock:true ~emits_metrics:true ()) timer
    (fun frame -> eval frame timer)

let daemon_internal eff =
  preserve ~leaf_name:"Effect.daemon"
    ~footprint:(footprint ~has_concurrency:true ~has_background:true ()) eff
  @@ fun frame ->
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

let daemon = daemon_internal

module Expert = struct
  type context = Effect_core.frame

  let footprint_of_capabilities capabilities =
    List.fold_left
      (fun acc -> function
        | `Clock -> union_footprint acc (footprint ~uses_clock:true ())
        | `Logs -> union_footprint acc (footprint ~emits_logs:true ())
        | `Metrics -> union_footprint acc (footprint ~emits_metrics:true ())
        | `Concurrency ->
            union_footprint acc (footprint ~has_concurrency:true ())
        | `Resources -> union_footprint acc (footprint ~has_resources:true ())
        | `Background ->
            union_footprint acc
              (footprint ~has_concurrency:true ~has_background:true ()))
      no_footprint capabilities

  let make ?leaf_name ?names ?inherit_ ~capabilities f =
    let footprint = footprint_of_capabilities capabilities in
    let footprint =
      match inherit_ with
      | None -> footprint
      | Some eff -> union_footprint (capability_footprint eff) footprint
    in
    Effect_core.make ?leaf_name ?names
      ~footprint f
  let contract context = context.runtime.Runtime_core.contract
  let current_scope context = context.sw
  let outer_scope context = context.runtime.Runtime_core.outer_scope
  let runtime_service context key = Runtime_core.service context.runtime key
  let auto_instrument context = context.runtime.Runtime_core.auto_instrument

  let instrument_leaf context ~name f =
    Runtime_instrument.instrument_leaf ~runtime:context.runtime
      ~error_renderer:context.error_renderer ~fail_key:context.fail_key ~name f

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

  let record_metric context ~name ~description ~unit_ ~kind ~attrs ~value =
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

  let eval context eff = Effect_core.eval context eff
  let eval_in_scope context sw eff = Effect_core.run_scope ~sw context eff
  let exit_of_exn context exn = Effect_core.exit_of_exn context exn
end
