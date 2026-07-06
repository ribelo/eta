(** Timer-node lifecycle orchestration for Eta_signal internals.

    Timer_policy owns pure state transitions and Timer_adapter owns daemon
    effects. This module owns graph-timer demand classification and lifecycle
    plan application: collect the graph's necessary timers, validate only timers
    that need runtime ownership, update current timer state, and assemble
    start/cancel effects in policy order. *)

type 'start demand_effects

val demand_effects_plan :
  'start demand_effects ->
  plan:(start_attempts:'start list -> cancel_hooks:(unit -> unit) list -> 'a) ->
  'a

type 'operation node

type 'operation start

val start :
  run:('err. 'operation node -> (unit, 'err) Eta.Effect.t) ->
  'operation start

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

val can_refresh_on_demand :
  token:int ->
  current_snapshot:Eta_signal_timer_policy.snapshot ->
  effective_state:Eta_signal_timer_policy.state ->
  _ node ->
  bool

val refresh_node_on_demand :
  validate_runtime:
    ('operation node ->
    Eta.Runtime_contract.t ->
    (unit, 'error) result) ->
  current_snapshot:('operation node -> Eta_signal_timer_policy.snapshot) ->
  effective_state:('operation node -> Eta_signal_timer_policy.state) ->
  remember:('operation node -> unit) ->
  run_operation:('operation node -> now_ms:int -> 'operation -> unit) ->
  (Eta.Runtime_contract.t, 'dirty) Eta_signal_timer_policy.refresh_context ->
  'operation node ->
  (unit, 'error) result

type ('timer, 'effect) start_attempt

type 'timer state_port

val state_port :
  effective:('timer -> Eta_signal_timer_policy.state) ->
  current:('timer -> Eta_signal_timer_policy.state) ->
  set_current:('timer -> Eta_signal_timer_policy.state -> unit) ->
  'timer state_port

type daemon_state_access

val daemon_state_access :
  with_state:('a 'error. (unit -> 'a) -> ('a, 'error) Eta.Effect.t) ->
  daemon_state_access

type 'timer daemon_update

val daemon_update :
  update:
    ('error.
     'timer -> generation:int -> missed:int -> (unit, 'error) Eta.Effect.t) ->
  'timer daemon_update

type daemon_hooks

val daemon_hooks :
  after_due_read_before_commit:
    ('error. unit -> (unit, 'error) Eta.Effect.t) ->
  after_update_constructed_before_run:
    ('error. unit -> (unit, 'error) Eta.Effect.t) ->
  daemon_hooks

type 'timer daemon_context

val daemon_context :
  advance_generation:(int -> int) ->
  state_access:daemon_state_access ->
  state:'timer state_port ->
  update:'timer daemon_update ->
  hooks:daemon_hooks ->
  'timer daemon_context

type ('id, 'operation, 'runtime, 'error) node_demand_plan

val node_demand_plan :
  timers:('id * 'operation node) list ->
  is_necessary:('id -> bool) ->
  validate_runtime:('runtime -> 'operation node -> (unit, 'error) result) ->
  state:'operation node state_port ->
  ('id, 'operation, 'runtime, 'error) node_demand_plan

type ('capability, 'error) demand_effect_access

val demand_effect_access :
  with_access:
    ('a.
     ('capability -> ('a, 'error) result) ->
     ('a, 'error) Eta.Effect.t) ->
  ('capability, 'error) demand_effect_access

type ('capability, 'id, 'operation, 'error) node_demand_effect_port

val node_demand_effect_port :
  plan:
    (Eta.Runtime_contract.t ->
    'capability ->
    ('id, 'operation, Eta.Runtime_contract.t, 'error) node_demand_plan) ->
  ('capability, 'id, 'operation, 'error) node_demand_effect_port

val mark_node_unneeded :
  advance_generation:(int -> int) ->
  cancel_running:bool ->
  'operation node state_port ->
  'operation node ->
  (unit -> unit) list

val preflight_start :
  advance_generation:(int -> int) -> 'timer state_port -> 'timer -> unit

val preflight_stop :
  advance_generation:(int -> int) -> 'timer state_port -> 'timer -> unit

val start_attempt_effects :
  ('timer, 'effect) start_attempt list -> 'effect list

val refresh_node_demand_plan :
  advance_generation:(int -> int) ->
  cancel_running:bool ->
  ('id, 'operation, 'runtime, 'error) node_demand_plan ->
  'runtime ->
  (('operation node, (unit, 'error) Eta.Effect.t) start_attempt
   demand_effects,
   'error)
  result

val refresh_node_demand_effect :
  advance_generation:(int -> int) ->
  ('capability, 'error) demand_effect_access ->
  ('capability, 'id, 'operation, 'error) node_demand_effect_port ->
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

val finish_node :
  advance_generation:(int -> int) -> 'timer state_port -> 'timer -> unit

val finish_saturated :
  advance_generation:(int -> int) ->
  'timer state_port ->
  'timer ->
  generation:int ->
  unit

val start_daemon :
  'timer daemon_context ->
  'timer ->
  generation:int ->
  interval_ms:int ->
  update_on_start:bool ->
  catch_up_policy:Eta_signal_timer_policy.catch_up_policy ->
  (unit, 'error) Eta.Effect.t

val create_daemon_node :
  runtime_contract:Eta.Runtime_contract.t ->
  refresh_when_inactive:bool ->
  refresh_operation:'operation option ->
  'operation node daemon_context ->
  interval_ms:int ->
  update_on_start:bool ->
  catch_up_policy:Eta_signal_timer_policy.catch_up_policy ->
  'operation node
