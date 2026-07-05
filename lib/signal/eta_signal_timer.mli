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

type 'operation node

type 'operation start = {
  run : 'err. 'operation node -> (unit, 'err) Eta.Effect.t;
}

val create_node :
  runtime_contract:Eta.Runtime_contract.t ->
  refresh_when_inactive:bool ->
  refresh_operation:'operation option ->
  start:'operation start ->
  'operation node

val snapshot_cell :
  'operation node ->
  Eta_signal_timer_policy.snapshot Eta_signal_transaction.staged

val staged_refresh_token : _ node -> int
val set_staged_refresh_token : _ node -> int -> unit
val runtime_contract : _ node -> Eta.Runtime_contract.t
val refresh_when_inactive : _ node -> bool
val refresh_operation : 'operation node -> 'operation option
val start_effect : 'operation node -> (unit, 'err) Eta.Effect.t

type ('timer, 'effect) start_attempt

type 'timer state_port = {
  state_effective : 'timer -> Eta_signal_timer_policy.state;
  state_current : 'timer -> Eta_signal_timer_policy.state;
  state_set_current : 'timer -> Eta_signal_timer_policy.state -> unit;
}

type daemon_state_access = {
  daemon_with_state :
    'a 'error. (unit -> 'a) -> ('a, 'error) Eta.Effect.t;
}

type 'timer daemon_update = {
  daemon_update :
    'error.
    'timer -> generation:int -> missed:int -> (unit, 'error) Eta.Effect.t;
}

type daemon_hooks = {
  daemon_after_due_read_before_commit :
    'error. unit -> (unit, 'error) Eta.Effect.t;
  daemon_after_update_constructed_before_run :
    'error. unit -> (unit, 'error) Eta.Effect.t;
}

type ('id, 'necessary, 'runtime, 'timer, 'effect, 'error) demand_port = {
  demand_collect_necessary : unit -> 'necessary;
  demand_collect_timers : unit -> ('id * 'timer) list;
  demand_is_necessary : 'necessary -> 'id -> bool;
  demand_validate_runtime : 'runtime -> 'timer -> (unit, 'error) result;
  demand_effective_state : 'timer -> Eta_signal_timer_policy.state;
  demand_current_state : 'timer -> Eta_signal_timer_policy.state;
  demand_set_current_state : 'timer -> Eta_signal_timer_policy.state -> unit;
  demand_start_effect : 'timer -> 'effect;
}

type ('id, 'necessary, 'operation, 'runtime, 'error) node_demand_port = {
  node_demand_necessary : 'necessary;
  node_demand_timers : ('id * 'operation node) list;
  node_demand_is_necessary : 'necessary -> 'id -> bool;
  node_demand_validate_runtime :
    'runtime -> 'operation node -> (unit, 'error) result;
  node_demand_state : 'operation node state_port;
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

type ('capability, 'operation, 'error) node_demand_effect_port = {
  node_demand_effect_acquire :
    Eta.Runtime_contract.t ->
    'capability ->
    (('operation node, (unit, 'error) Eta.Effect.t) start_attempt
     demand_effects,
     'error)
    result;
  node_demand_effect_state : 'operation node state_port;
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

val start_attempt_effects :
  ('timer, 'effect) start_attempt list -> 'effect list

val rollback_unclaimed_start_attempts :
  advance_generation:(int -> int) ->
  'timer state_port ->
  ('timer, 'effect) start_attempt list ->
  (unit -> unit) list

val refresh_demand :
  advance_generation:(int -> int) ->
  cancel_running:bool ->
  ('id, 'necessary, 'runtime, 'timer, 'effect, 'error) demand_port ->
  'runtime ->
  (('timer, 'effect) start_attempt demand_effects, 'error) result

val refresh_node_demand :
  advance_generation:(int -> int) ->
  cancel_running:bool ->
  ('id, 'necessary, 'operation, 'runtime, 'error) node_demand_port ->
  'runtime ->
  (('operation node, (unit, 'error) Eta.Effect.t) start_attempt
   demand_effects,
   'error)
  result

val refresh_demand_effect :
  ('capability, 'error) demand_effect_access ->
  ('capability, 'start, 'error) demand_effect_port ->
  (unit, 'error) Eta.Effect.t

val refresh_node_demand_effect :
  advance_generation:(int -> int) ->
  ('capability, 'error) demand_effect_access ->
  ('capability, 'operation, 'error) node_demand_effect_port ->
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

val start_daemon :
  advance_generation:(int -> int) ->
  daemon_state_access ->
  'timer state_port ->
  'timer ->
  'timer daemon_update ->
  daemon_hooks ->
  generation:int ->
  interval_ms:int ->
  update_on_start:bool ->
  catch_up_policy:Eta_signal_timer_policy.catch_up_policy ->
  (unit, 'error) Eta.Effect.t

val create_daemon_node :
  runtime_contract:Eta.Runtime_contract.t ->
  refresh_when_inactive:bool ->
  refresh_operation:'operation option ->
  advance_generation:(int -> int) ->
  daemon_state_access ->
  'operation node state_port ->
  'operation node daemon_update ->
  daemon_hooks ->
  interval_ms:int ->
  update_on_start:bool ->
  catch_up_policy:Eta_signal_timer_policy.catch_up_policy ->
  'operation node
