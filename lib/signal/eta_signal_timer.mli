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

val mark_unneeded :
  advance_generation:(int -> int) ->
  cancel_running:bool ->
  current_state:('timer -> Eta_signal_timer_policy.state) ->
  set_current_state:('timer -> Eta_signal_timer_policy.state -> unit) ->
  'timer ->
  (unit -> unit) list

val rollback_unclaimed_start :
  advance_generation:(int -> int) ->
  current_state:('timer -> Eta_signal_timer_policy.state) ->
  set_current_state:('timer -> Eta_signal_timer_policy.state -> unit) ->
  'timer ->
  (unit -> unit) list

val refresh_demand :
  advance_generation:(int -> int) ->
  cancel_running:bool ->
  ('id, 'necessary, 'runtime, 'timer, 'start, 'error) demand_port ->
  'runtime ->
  ('start demand_effects, 'error) result
