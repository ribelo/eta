(** Public Effect surface — a barrel that re-exports the decomposed
    implementation modules ([effect_core], [effect_resource], etc.) and adds
    the runtime entry point [run] plus internal access via [Private]. The
    public type and value signatures live in [effect.mli]. *)

open Effect_core

include Effect_core
include Effect_resource
include Effect_concurrent
include Effect_observability
include Effect_supervisor_scope
include Effect_island
include Effect_blocking

let daemon_internal effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  Runtime_core.incr_active frame.runtime;
  fiber_fork_daemon frame ~sw:frame.runtime.outer_sw (fun () ->
      frame.runtime.tracer#with_fiber_context @@ fun () ->
      Fun.protect
        ~finally:(fun () -> Runtime_core.decr_active frame.runtime)
        (fun () ->
          (try
             switch_run frame @@ fun sw ->
             let finalizers = ref [] in
             let child_frame =
               { frame with sw; finalizers; error_renderer = default_renderer }
             in
             Runtime_core.with_finalizers ~runtime:frame.runtime
               ~fail_key:frame.runtime.default_fail_key
               ~error_renderer:child_frame.error_renderer finalizers (fun () ->
                 run_to_value child_frame effect)
           with exn ->
             Runtime_core.cause_of_exn_runtime frame.runtime
               frame.runtime.default_fail_key exn
             |> Runtime_core.emit_daemon_failure frame.runtime);
          `Stop_daemon));
  ok ()

let run runtime effect =
  if Blocking_runtime.in_worker () then
    invalid_arg
      "Eta.Runtime.run must not be called from inside an Effect.Blocking worker callback";
  runtime.Runtime_core.tracer#with_fiber_context @@ fun () ->
  let finalizers = ref [] in
  let frame =
    {
      (* [Effect_core.frame] stores the runtime with an erased failure type
         because a single run can cross effects with different typed-failure
         parameters. Runtime_core keeps failures keyed separately, so this cast
         only erases the phantom carrier on the runtime value. *)
      runtime = (Obj.magic runtime : Obj.t Runtime_core.t);
      error_renderer = default_renderer;
      fail_key = runtime.Runtime_core.default_fail_key;
      sw = runtime.Runtime_core.outer_sw;
      finalizers;
    }
  in
  try
    let body () =
      Runtime_core.with_finalizers ~runtime ~fail_key:runtime.default_fail_key
        ~error_renderer:frame.error_renderer finalizers (fun () ->
          run_to_value frame effect)
    in
    ok
      (if runtime.Runtime_core.tracing_enabled
       || runtime.Runtime_core.metrics_enabled
      then
        RObs.with_blocking_event_emit
          (Runtime_core.emit_blocking_event runtime)
          body
      else body ())
  with exn ->
    error (Runtime_core.cause_of_exn_runtime runtime runtime.default_fail_key exn)

module Private = struct
  let daemon = daemon_internal

  let named_attrs ~kind name ~attrs effect =
    annotate_all attrs (named_kind ~kind name effect)

  let metric_updates = metric_updates
  let metric_updates_lazy = metric_updates_lazy
end
