(** Public Effect implementation. *)

open Effect_core

include Effect_core
include Effect_resource
include Effect_concurrent
include Effect_observability
include Effect_supervisor_scope
include Effect_schedule

module Scoped = struct
  let acquire_into owner ~acquire ~release =
    preserve acquire @@ fun child ->
    match eval child acquire with
    | Exit.Error _ as err -> err
    | Exit.Ok value ->
        eval owner (acquire_release ~acquire:(pure value) ~release)

  let with_owner names f =
    with_scope (make ~names (fun owner -> eval owner (f owner)))

  let with_2 ~acquire1 ~release1 ~acquire2 ~release2 body =
    with_owner (names acquire1 @ names acquire2) @@ fun owner ->
    par
      (acquire_into owner ~acquire:acquire1 ~release:release1)
      (acquire_into owner ~acquire:acquire2 ~release:release2)
    |> bind (fun (resource1, resource2) -> body resource1 resource2)

  let with_3 ~acquire1 ~release1 ~acquire2 ~release2 ~acquire3 ~release3 body =
    with_owner (names acquire1 @ names acquire2 @ names acquire3) @@ fun owner ->
    par
      (acquire_into owner ~acquire:acquire1 ~release:release1)
      (par
         (acquire_into owner ~acquire:acquire2 ~release:release2)
         (acquire_into owner ~acquire:acquire3 ~release:release3))
    |> bind (fun (resource1, (resource2, resource3)) ->
           body resource1 resource2 resource3)
end

let metric_timer ?description ?(unit_ = "ms") ?attrs ~name ~boundaries eff =
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

let daemon_internal eff =
  preserve eff @@ fun frame ->
  Runtime_core.incr_active frame.runtime;
  fiber_fork_daemon frame ~sw:frame.runtime.outer_scope (fun () ->
      frame.runtime.tracer#with_task_context frame.runtime.contract @@ fun () ->
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

  let make ?leaf_name ?names f = Effect_core.make ?leaf_name ?names f
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
    if runtime.Runtime_core.tracing_enabled then
      match
        runtime.contract.Runtime_contract.local_get
          Runtime_observability.active_span_key
      with
      | None -> ()
      | Some span_id ->
          runtime.tracer#add_event runtime.contract ~span_id ~name
            ~ts_ms:(runtime.now_ms ()) ~attrs

  let record_metric context ~name ~description ~unit_ ~kind ~attrs ~value =
    let runtime = context.runtime in
    if runtime.Runtime_core.metrics_enabled then
      runtime.meter#record
        {
          Capabilities.name;
          description;
          unit_;
          kind;
          attrs;
          value;
          ts_ms = runtime.now_ms ();
        }

  let fork_daemon context f =
    Runtime_core.incr_active context.runtime;
    context.runtime.contract.Runtime_contract.fork_daemon
      context.runtime.outer_scope (fun () ->
          context.runtime.tracer#with_task_context context.runtime.contract
          @@ fun () ->
          Fun.protect
            ~finally:(fun () -> Runtime_core.decr_active context.runtime)
            f)

  let eval context eff = Effect_core.eval context eff
  let eval_in_scope context sw eff = Effect_core.run_scope ~sw context eff
  let exit_of_exn context exn = Effect_core.exit_of_exn context exn
end
