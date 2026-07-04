(** Pure stabilization pass orchestration for Eta_signal internals. *)

type ('owner, 'hook, 'event, 'error) result =
  | Pure_ok of
      'hook list
      * 'event list
      * ('owner, Eta_signal_stabilization.delivering)
        Eta_signal_stabilization.token
  | Pure_graph_error of 'hook list * 'error
  | Pure_defect of 'hook list * exn * Printexc.raw_backtrace

type 'error errors = {
  reentrant_stabilization : 'error;
  classify_graph_error : exn -> 'error option;
}

type 'capability pure_context
type 'capability rollback_context
type 'capability timer_refresh_context

val pure_capability : 'capability pure_context -> 'capability
val rollback_capability : 'capability rollback_context -> 'capability
val timer_refresh_capability : 'capability timer_refresh_context -> 'capability

type ('capability, 'pending, 'observer, 'event, 'hook, 'staging) pure = {
  advance_generation : 'capability pure_context -> unit;
  begin_staging : 'capability pure_context -> 'staging;
  drain_pending : 'capability pure_context -> 'pending list;
  release_pending_marks : 'capability pure_context -> 'pending list -> unit;
  active_observers : 'capability pure_context -> 'observer list;
  stage_pending : 'capability pure_context -> 'pending list -> unit;
  plan_staged_binds : 'capability pure_context -> 'observer list -> unit;
  sort_delivery_observers :
    'capability pure_context -> 'observer list -> 'observer list;
  collect_events : 'capability pure_context -> 'observer list -> 'event list;
  commit_staging : 'capability pure_context -> 'staging -> 'hook list;
  mark_events_pending : 'capability pure_context -> 'event list -> unit;
  update_necessity : 'capability pure_context -> unit;
}

type ('capability, 'pending, 'observer, 'hook, 'staging) rollback = {
  rollback_staging : 'capability rollback_context -> 'staging -> 'hook list;
  mark_observers_failed_without_current :
    'capability rollback_context -> 'observer list -> unit;
  requeue_pending : 'capability rollback_context -> 'pending list -> unit;
}

type 'capability timer_refresh = {
  clear_active_timer_refresh : 'capability timer_refresh_context -> unit;
}

type ('capability, 'pending, 'observer, 'event, 'hook, 'error, 'staging) t = {
  errors : 'error errors;
  pure :
    ('capability, 'pending, 'observer, 'event, 'hook, 'staging) pure;
  rollback : ('capability, 'pending, 'observer, 'hook, 'staging) rollback;
  timer_refresh : 'capability timer_refresh;
}
(** Capability surface for graph-specific work performed in a pure
    stabilization pass. The module owns callback ordering, phase transitions,
    and rollback cleanup; callers provide grouped graph operations. Each
    callback receives a phase-specific context so pure, rollback, and timer
    cleanup operations cannot be interchanged accidentally. *)

val run :
  ('owner, 'error) Eta_signal_stabilization.t ->
  'capability ->
  ('capability, 'pending, 'observer, 'event, 'hook, 'error, 'staging) t ->
  ('owner, 'hook, 'event, 'error) result

type ('event, 'error) delivery = {
  run_pending_cleanup : unit -> (unit, 'error) Eta.Effect.t;
  run_events : 'event list -> (unit, 'error) Eta.Effect.t;
  mark_complete : unit -> (unit, 'error) Eta.Effect.t;
  finish : unit -> (unit, 'error) Eta.Effect.t;
}
(** Callback surface for the delivering phase. The module owns delivery
    bracketing: cleanup before callbacks, callbacks, completion marking, final
    cleanup, and phase finish. *)

val deliver :
  ('event, 'error) delivery ->
  'event list ->
  (unit, 'error) Eta.Effect.t

val finish_delivery :
  ('event, 'error) delivery ->
  (unit, 'error) Eta.Effect.t
