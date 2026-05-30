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
               ~fail_key:frame.runtime.default_fail_key finalizers (fun () ->
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
        finalizers (fun () -> run_to_value frame effect)
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

  let island_submit = Island_runtime.submit
  let island_submit_map = Island_runtime.submit_map
  let island_submit_map_result = Island_runtime.submit_map_result
  let island_submit_all_settled = Island_runtime.submit_all_settled

  type blocking_outcome = Blocking_runtime.outcome =
    | Blocking_ok
    | Blocking_error of string
    | Blocking_cancelled
    | Blocking_rejected
    | Blocking_shutdown_rejected
    | Blocking_detached

  type blocking_event = Blocking_runtime.event = {
    pool : string;
    name : string;
    queue_wait_ms : int;
    run_ms : int;
    outcome : blocking_outcome;
  }

  let blocking_default_config = Blocking_runtime.default_config
  let blocking_submit = Blocking_runtime.submit
  let blocking_pool_name = Blocking_runtime.name
  let in_blocking_worker = Blocking_runtime.in_worker

  let make_supervisor = Runtime_supervisor.make
  let supervisor_fork = Runtime_supervisor.fork
  let supervisor_max_failures = Runtime_supervisor.max_failures
  let supervisor_record_failure = Runtime_supervisor.record_failure
  let supervisor_failures = Runtime_supervisor.failures
  let supervisor_failure_count = Runtime_supervisor.failure_count
  let supervisor_register_child = Runtime_supervisor.register_child
  let supervisor_cancel_children = Runtime_supervisor.cancel_children
  let make_supervisor_child = Runtime_supervisor.make_child
  let supervisor_child_promise = Runtime_supervisor.child_promise
  let supervisor_child_cancel = Runtime_supervisor.child_cancel
end
