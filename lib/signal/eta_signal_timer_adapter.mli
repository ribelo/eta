(** Effectful timer daemon adapter for Eta_signal internals.

    Timer_policy owns pure timer state transitions. This module owns the
    effectful daemon loop: cancellation normalization, clock/sleep scheduling,
    due advancement, and batched update ordering. Graph-specific mutation stays
    behind callbacks. *)

type continue =
  [ `Continue
  | `Stop
  ]

type advance =
  [ `Advanced
  | `Stale
  | `Stop
  ]

type ('capability, 'error) access

val access :
  with_access:
    ('a. ('capability -> ('a, 'error) result) -> ('a, 'error) Eta.Effect.t) ->
  ('capability, 'error) access

type 'error loop_due_plan

val loop_due_plan :
  read_next_due:
    (generation:int -> fallback:int -> (int option, 'error) Eta.Effect.t) ->
  advance_next_due:
    (generation:int ->
    expected:int ->
    next_due_ms:int ->
    (advance, 'error) Eta.Effect.t) ->
  after_due_read_before_commit:(unit -> (unit, 'error) Eta.Effect.t) ->
  'error loop_due_plan

type 'error loop_update_plan

val loop_update_plan :
  after_update_state:
    (generation:int -> (continue, 'error) Eta.Effect.t) ->
  construct_update:
    (generation:int -> missed:int -> (unit, 'error) Eta.Effect.t) ->
  after_update_constructed_before_run:
    (unit -> (unit, 'error) Eta.Effect.t) ->
  'error loop_update_plan

type 'error loop_finish_plan

val loop_finish_plan :
  finish_saturated:(generation:int -> (unit, 'error) Eta.Effect.t) ->
  'error loop_finish_plan

type 'error loop_plan

val loop_plan :
  due:'error loop_due_plan ->
  updates:'error loop_update_plan ->
  finish:'error loop_finish_plan ->
  'error loop_plan

type 'error start_gate_plan

val start_gate_plan :
  begin_start:(generation:int -> (continue, 'error) Eta.Effect.t) ->
  set_next_due:
    (generation:int ->
    next_due_ms:int ->
    (continue, 'error) Eta.Effect.t) ->
  'error start_gate_plan

type 'error start_update_plan

val start_update_plan :
  construct_start_update:
    (generation:int -> missed:int -> (unit, 'error) Eta.Effect.t) ->
  after_start_update:
    (generation:int -> (continue, 'error) Eta.Effect.t) ->
  'error start_update_plan

type 'error start_daemon_plan

val start_daemon_plan :
  install_cancel:
    (generation:int ->
    cancel:(unit -> unit) ->
    (continue, 'error) Eta.Effect.t) ->
  cleanup_after_exit:
    (generation:int ->
    (unit, 'error) Eta.Exit.t ->
    (unit, 'error) Eta.Effect.t) ->
  cleanup_failed_start:
    (generation:int ->
    (unit, 'error) Eta.Exit.t ->
    (unit, 'error) Eta.Effect.t) ->
  'error start_daemon_plan

type 'error start_plan

val start_plan :
  gate:'error start_gate_plan ->
  update:'error start_update_plan ->
  daemon:'error start_daemon_plan ->
  'error start_plan

type ('attempt, 'cancel_hook) demand_claim

val demand_claim :
  start_attempts:'attempt list ->
  cancel_hooks:'cancel_hook list ->
  ('attempt, 'cancel_hook) demand_claim

type ('capability, 'attempt, 'cancel_hook, 'error) demand_claim_plan

val demand_claim_plan :
  acquire:
    (Eta.Runtime_contract.t ->
    'capability ->
    (('attempt, 'cancel_hook) demand_claim, 'error) result) ->
  rollback_unclaimed:
    ('capability -> 'attempt list -> ('cancel_hook list, 'error) result) ->
  ('capability, 'attempt, 'cancel_hook, 'error) demand_claim_plan

type ('attempt, 'cancel_hook, 'error) demand_effect_plan

val demand_effect_plan :
  run_cancel_hooks:
    ('cancel_hook list -> (unit, 'error) Eta.Effect.t) ->
  run_start_attempts:('attempt list -> (unit, 'error) Eta.Effect.t) ->
  ('attempt, 'cancel_hook, 'error) demand_effect_plan

type ('capability, 'attempt, 'cancel_hook, 'error) demand_plan

val demand_plan :
  claim:('capability, 'attempt, 'cancel_hook, 'error) demand_claim_plan ->
  effects:('attempt, 'cancel_hook, 'error) demand_effect_plan ->
  ('capability, 'attempt, 'cancel_hook, 'error) demand_plan

val run_cancellable :
  install_cancel:
    (cancel:(unit -> unit) -> (continue, 'error) Eta.Effect.t) ->
  loop:(unit, 'error) Eta.Effect.t ->
  (unit, 'error) Eta.Effect.t

val refresh_demand :
  ('capability, 'error) access ->
  ('capability, 'attempt, 'cancel_hook, 'error) demand_plan ->
  (unit, 'error) Eta.Effect.t

val run_loop :
  'error loop_plan ->
  generation:int ->
  interval_ms:int ->
  next_due_ms:int ->
  catch_up_policy:Eta_signal_timer_policy.catch_up_policy ->
  (unit, 'error) Eta.Effect.t

val start :
  'error start_plan ->
  'error loop_plan ->
  generation:int ->
  interval_ms:int ->
  update_on_start:bool ->
  catch_up_policy:Eta_signal_timer_policy.catch_up_policy ->
  (unit, 'error) Eta.Effect.t
