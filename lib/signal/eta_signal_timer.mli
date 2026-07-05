(** Timer-node lifecycle orchestration for Eta_signal internals.

    Timer_policy owns pure state transitions and Timer_adapter owns daemon
    effects. This module owns graph-timer demand classification and lifecycle
    plan application: collect the graph's necessary timers, validate only timers
    that need runtime ownership, update current timer state, and assemble
    start/cancel effects in policy order. *)

type 'start demand_effects = {
  demand_start_attempts : 'start list;
  demand_cancel_hooks : (unit -> unit) list;
}

type 'timer state_port = {
  state_effective : 'timer -> Eta_signal_timer_policy.state;
  state_current : 'timer -> Eta_signal_timer_policy.state;
  state_set_current : 'timer -> Eta_signal_timer_policy.state -> unit;
}

type ('id, 'necessary, 'runtime, 'timer, 'start, 'error) demand_port = {
  demand_collect_necessary : unit -> 'necessary;
  demand_collect_timers : unit -> ('id * 'timer) list;
  demand_is_necessary : 'necessary -> 'id -> bool;
  demand_validate_runtime : 'runtime -> 'timer -> (unit, 'error) result;
  demand_effective_state : 'timer -> Eta_signal_timer_policy.state;
  demand_current_state : 'timer -> Eta_signal_timer_policy.state;
  demand_set_current_state : 'timer -> Eta_signal_timer_policy.state -> unit;
  demand_start_attempt : 'timer -> 'start;
}

type ('capability, 'error) demand_effect_access = {
  demand_with_access :
    'a.
    ('capability -> ('a, 'error) result) ->
    ('a, 'error) Eta.Effect.t;
}

type ('capability, 'start, 'error) demand_effect_port = {
  demand_acquire :
    Eta.Runtime_contract.t ->
    'capability ->
    ('start demand_effects, 'error) result;
  demand_rollback_unclaimed :
    'capability -> 'start list -> ((unit -> unit) list, 'error) result;
  demand_run_cancel_hooks :
    (unit -> unit) list -> (unit, 'error) Eta.Effect.t;
  demand_run_start_attempts :
    'start list -> (unit, 'error) Eta.Effect.t;
}

val mark_unneeded :
  advance_generation:(int -> int) ->
  cancel_running:bool ->
  'timer state_port ->
  'timer ->
  (unit -> unit) list

val rollback_unclaimed_start :
  advance_generation:(int -> int) ->
  'timer state_port ->
  'timer ->
  (unit -> unit) list

val refresh_demand :
  advance_generation:(int -> int) ->
  cancel_running:bool ->
  ('id, 'necessary, 'runtime, 'timer, 'start, 'error) demand_port ->
  'runtime ->
  ('start demand_effects, 'error) result

val refresh_demand_effect :
  ('capability, 'error) demand_effect_access ->
  ('capability, 'start, 'error) demand_effect_port ->
  (unit, 'error) Eta.Effect.t

val begin_start :
  'timer state_port ->
  'timer ->
  generation:int ->
  [ `Continue | `Stop ]

val install_cancel :
  'timer state_port ->
  'timer ->
  generation:int ->
  cancel:(unit -> unit) ->
  [ `Continue | `Stop ]

val cleanup_after_exit :
  advance_generation:(int -> int) ->
  'timer state_port ->
  'timer ->
  generation:int ->
  Eta_signal_timer_policy.daemon_exit ->
  unit

val cleanup_failed_start :
  advance_generation:(int -> int) ->
  'timer state_port ->
  'timer ->
  generation:int ->
  Eta_signal_timer_policy.daemon_exit ->
  unit

val after_update_state :
  'timer state_port ->
  'timer ->
  generation:int ->
  [ `Continue | `Stop ]

val publish_if_running :
  'timer state_port ->
  'timer ->
  generation:int ->
  publish:(unit -> unit) ->
  [ `Stopped | `Updated ]

val read_next_due :
  'timer state_port ->
  'timer ->
  generation:int ->
  fallback:int ->
  int option

val set_next_due :
  'timer state_port ->
  'timer ->
  generation:int ->
  next_due_ms:int ->
  [ `Continue | `Stop ]

val advance_next_due :
  'timer state_port ->
  'timer ->
  generation:int ->
  expected:int ->
  next_due_ms:int ->
  [ `Advanced | `Stale | `Stop ]

val finish_saturated :
  advance_generation:(int -> int) ->
  'timer state_port ->
  'timer ->
  generation:int ->
  unit
