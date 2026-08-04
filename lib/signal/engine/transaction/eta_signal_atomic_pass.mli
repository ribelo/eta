type fault_slot =
  | Before_phase_install
  | After_phase_install
  | After_dynamic_discovery
  | After_frontier_freeze
  | After_discard_partition
  | After_prospective_validation
  | Before_plan_seal
  | Before_total_commit

type counters
type counter_snapshot = {
  phase_entries : int;
  commits : int;
  rollback_calls : int;
  returns_to_idle : int;
}

val create_counters : unit -> counters
val reset_counters : counters -> unit
val disable_counters : counters -> unit
val counter_snapshot : counters -> counter_snapshot
val note_phase_entry : counters -> unit
val note_commit : counters -> unit
val note_rollback : counters -> unit
val note_return_to_idle : counters -> unit

type fault = { slot : fault_slot; exn : exn }
type fault_injector

val create_fault_injector : unit -> fault_injector
val set_fault : fault_injector -> fault option -> unit
val check_fault : fault_injector -> fault_slot -> unit

type phase =
  | Idle
  | Planning
  | Delivering

type ('owner, 'error) t

val create : unit -> ('owner, 'error) t
val phase : (_, _) t -> phase
val is_planning : (_, _) t -> bool
val counters : (_, _) t -> counters
val commit_counters : (_, _) t -> Eta_signal_commit_plan.counters
val fault_injector : (_, _) t -> fault_injector

val active_transaction :
  (_, 'error) t ->
  (Eta_signal_transaction.planning, 'error) Eta_signal_transaction.t

val commit_transaction : (_, _) t -> unit
val rollback_transaction : (_, _) t -> unit

val new_commit_plan :
  (_, _) t -> (Eta_signal_commit_plan.open_, 'hook) Eta_signal_commit_plan.t

type ('event, 'hook, 'error) result

val graph_error :
  hooks:'hook list -> 'error -> ('event, 'hook, 'error) result

val result :
  ('event, 'hook, 'error) result ->
  planning_ok:(hooks:'hook list -> events:'event list -> 'a) ->
  graph_error:(hooks:'hook list -> 'error -> 'a) ->
  defect:(hooks:'hook list -> exn -> Printexc.raw_backtrace -> 'a) ->
  'a

type ('capability, 'observer, 'event) observer_snapshot

val observer_snapshot :
  observers:'observer list ->
  collect_events:('capability -> 'observer list -> 'event list) ->
  mark_events_pending:('capability -> 'event list -> unit) ->
  ('capability, 'observer, 'event) observer_snapshot

type ('capability, 'pending, 'observer, 'event, 'hook, 'error, 'staging) ops

val ops :
  reentrant_error:'error ->
  classify_graph_error:(exn -> 'error option) ->
  advance_generation:('capability -> unit) ->
  begin_staging:('capability -> 'staging) ->
  drain_pending:('capability -> 'pending list) ->
  release_pending_marks:('capability -> 'pending list -> unit) ->
  observer_snapshot:
    ('capability -> ('capability, 'observer, 'event) observer_snapshot) ->
  stage_pending:('capability -> 'pending list -> unit) ->
  plan_dynamic:('capability -> 'observer list -> unit) ->
  prepare_commit:
    ('capability ->
    'staging ->
    ((Eta_signal_commit_plan.open_, 'hook) Eta_signal_commit_plan.t, 'error)
    Stdlib.result) ->
  update_necessity:('capability -> unit) ->
  clear_timer_refresh:('capability -> unit) ->
  rollback_staging:('capability -> 'staging -> 'hook list) ->
  mark_observers_failed:('capability -> 'observer list -> unit) ->
  requeue_pending:('capability -> 'pending list -> unit) ->
  ('capability, 'pending, 'observer, 'event, 'hook, 'error, 'staging) ops

val run :
  ('owner, 'error) t ->
  'capability ->
  ('capability, 'pending, 'observer, 'event, 'hook, 'error, 'staging) ops ->
  ('event, 'hook, 'error) result

val finish_delivering : (_, _) t -> unit

type ('event, 'error) delivery

val delivery :
  run_pending_cleanup:(unit -> (unit, 'error) Eta.Effect.t) ->
  run_events:('event list -> (unit, 'error) Eta.Effect.t) ->
  mark_complete:(unit -> (unit, 'error) Eta.Effect.t) ->
  finish:(unit -> (unit, 'error) Eta.Effect.t) ->
  ('event, 'error) delivery

val deliver :
  ('event, 'error) delivery ->
  'event list ->
  (unit, 'error) Eta.Effect.t

val finish_delivery :
  ('event, 'error) delivery ->
  (unit, 'error) Eta.Effect.t
