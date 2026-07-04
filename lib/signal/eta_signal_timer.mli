(** Timer-node lifecycle orchestration for Eta_signal internals.

    Timer_policy owns pure state transitions and Timer_adapter owns daemon
    effects. This module owns graph-timer demand classification: collect the
    graph's necessary timers, validate only timers that need runtime ownership,
    and assemble start/cancel effects in policy order. *)

type ('start, 'hook) demand_effects = {
  demand_start_attempts : 'start list;
  demand_cancel_hooks : 'hook list;
}

type ('id, 'necessary, 'runtime, 'timer, 'start, 'hook, 'error) demand_port = {
  demand_collect_necessary : unit -> 'necessary;
  demand_collect_timers : unit -> ('id * 'timer) list;
  demand_is_necessary : 'necessary -> 'id -> bool;
  demand_validate_runtime : 'runtime -> 'timer -> (unit, 'error) result;
  demand_effective_state : 'timer -> Eta_signal_timer_policy.state;
  demand_current_state : 'timer -> Eta_signal_timer_policy.state;
  demand_plan_start : 'timer -> Eta_signal_timer_policy.start_plan -> 'start;
  demand_plan_stop :
    'timer -> Eta_signal_timer_policy.stop_plan -> 'hook list;
}

val refresh_demand :
  advance_generation:(int -> int) ->
  cancel_running:bool ->
  ('id, 'necessary, 'runtime, 'timer, 'start, 'hook, 'error) demand_port ->
  'runtime ->
  (('start, 'hook) demand_effects, 'error) result
