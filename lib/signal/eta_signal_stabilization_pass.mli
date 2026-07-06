(** Pure stabilization pass orchestration for Eta_signal internals. *)

type ('owner, 'hook, 'event, 'error) result

val graph_error :
  hooks:'hook list -> 'error -> ('owner, 'hook, 'event, 'error) result

val result :
  ('owner, 'hook, 'event, 'error) result ->
  pure_ok:
    (hooks:'hook list ->
    events:'event list ->
    delivering_token:
      ('owner, Eta_signal_stabilization.delivering)
      Eta_signal_stabilization.token ->
    'a) ->
  graph_error:(hooks:'hook list -> 'error -> 'a) ->
  defect:(hooks:'hook list -> exn -> Printexc.raw_backtrace -> 'a) ->
  'a

type 'error errors

val errors :
  reentrant_stabilization:'error ->
  classify_graph_error:(exn -> 'error option) ->
  'error errors

type 'capability pure_context
type 'capability rollback_context
type 'capability timer_refresh_context

val pure_capability : 'capability pure_context -> 'capability
val rollback_capability : 'capability rollback_context -> 'capability
val timer_refresh_capability : 'capability timer_refresh_context -> 'capability

type ('capability, 'observer, 'event) observer_plan

val observer_plan :
  observers:'observer list ->
  collect_events:
    ('capability pure_context -> 'observer list -> 'event list) ->
  mark_events_pending:('capability pure_context -> 'event list -> unit) ->
  ('capability, 'observer, 'event) observer_plan
(** Observer delivery plan for a pure pass. The pass owns when the active
    observer snapshot is captured, when events are collected, and when pending
    delivery state is marked; graph code owns how those steps traverse its
    registry. *)

type ('capability, 'pending, 'observer, 'event, 'hook, 'staging) pure

type 'capability pure_generation_plan

val pure_generation_plan :
  advance_generation:('capability pure_context -> unit) ->
  'capability pure_generation_plan

type ('capability, 'staging) pure_staging_plan

val pure_staging_plan :
  begin_staging:('capability pure_context -> 'staging) ->
  ('capability, 'staging) pure_staging_plan

type ('capability, 'pending) pure_pending_plan

val pure_pending_plan :
  drain_pending:('capability pure_context -> 'pending list) ->
  release_pending_marks:
    ('capability pure_context -> 'pending list -> unit) ->
  stage_pending:('capability pure_context -> 'pending list -> unit) ->
  ('capability, 'pending) pure_pending_plan

type ('capability, 'observer, 'event) pure_observer_plan

val pure_observer_plan :
  observer_plan:
    ('capability pure_context ->
    ('capability, 'observer, 'event) observer_plan) ->
  plan_staged_binds:
    ('capability pure_context -> 'observer list -> unit) ->
  ('capability, 'observer, 'event) pure_observer_plan

type ('capability, 'hook, 'staging) pure_commit_plan

val pure_commit_plan :
  commit_staging:
    ('capability pure_context -> 'staging -> 'hook list) ->
  update_necessity:('capability pure_context -> unit) ->
  ('capability, 'hook, 'staging) pure_commit_plan

val pure_ops :
  generation:'capability pure_generation_plan ->
  staging:('capability, 'staging) pure_staging_plan ->
  pending:('capability, 'pending) pure_pending_plan ->
  observers:('capability, 'observer, 'event) pure_observer_plan ->
  commit:('capability, 'hook, 'staging) pure_commit_plan ->
  ('capability, 'pending, 'observer, 'event, 'hook, 'staging) pure

type ('capability, 'pending, 'observer, 'hook, 'staging) rollback

val rollback_ops :
  rollback_staging:
    ('capability rollback_context -> 'staging -> 'hook list) ->
  mark_observers_failed_without_current:
    ('capability rollback_context -> 'observer list -> unit) ->
  requeue_pending:
    ('capability rollback_context -> 'pending list -> unit) ->
  ('capability, 'pending, 'observer, 'hook, 'staging) rollback

type 'capability timer_refresh

val timer_refresh_ops :
  clear_active_timer_refresh:
    ('capability timer_refresh_context -> unit) ->
  'capability timer_refresh

type ('capability, 'pending, 'observer, 'event, 'hook, 'error, 'staging) t

val pass_ops :
  errors:'error errors ->
  pure:
    ('capability, 'pending, 'observer, 'event, 'hook, 'staging) pure ->
  rollback:
    ('capability, 'pending, 'observer, 'hook, 'staging) rollback ->
  timer_refresh:'capability timer_refresh ->
  ('capability, 'pending, 'observer, 'event, 'hook, 'error, 'staging) t
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

type ('event, 'error) delivery

type 'error delivery_cleanup_plan

val delivery_cleanup_plan :
  run_pending_cleanup:(unit -> (unit, 'error) Eta.Effect.t) ->
  finish:(unit -> (unit, 'error) Eta.Effect.t) ->
  'error delivery_cleanup_plan

type ('event, 'error) delivery_event_plan

val delivery_event_plan :
  run_events:('event list -> (unit, 'error) Eta.Effect.t) ->
  mark_complete:(unit -> (unit, 'error) Eta.Effect.t) ->
  ('event, 'error) delivery_event_plan

val delivery_ops :
  cleanup:'error delivery_cleanup_plan ->
  events:('event, 'error) delivery_event_plan ->
  ('event, 'error) delivery
(** Plan surface for the delivering phase. The module owns delivery bracketing:
    cleanup before callbacks, callbacks, completion marking, final cleanup, and
    phase finish. *)

val deliver :
  ('event, 'error) delivery ->
  'event list ->
  (unit, 'error) Eta.Effect.t

val finish_delivery :
  ('event, 'error) delivery ->
  (unit, 'error) Eta.Effect.t
