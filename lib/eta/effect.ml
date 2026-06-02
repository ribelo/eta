(** Public Effect implementation. *)

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
                 run_to_value child_frame effect)
           with exn ->
             Runtime_core.cause_of_exn_runtime frame.runtime
               frame.runtime.default_fail_key exn
             |> Runtime_core.emit_daemon_failure frame.runtime);
          `Stop_daemon));
  ok ()

module Private = struct
  let daemon = daemon_internal

  let named_attrs ~kind name ~attrs effect =
    annotate_all attrs (named_kind ~kind name effect)

  let metric_updates = metric_updates
  let metric_updates_lazy = metric_updates_lazy
end
