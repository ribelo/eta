(** Pure timer policy helpers for Eta_signal internals.

    This module deliberately does not own timer graph nodes, runtime checks, or
    daemon wiring. Those remain adapter responsibilities. *)

type catch_up_policy =
  | Catch_up_every_cadence
  | Catch_up_once_per_wake
  | Catch_up_coalesced

type state

type snapshot

type ('runtime, 'dirty) refresh_context

type debug_snapshot = {
  debug_state_label : string;
  debug_active : bool;
  debug_running_generation : int option;
  debug_has_cancel : bool;
  debug_finished : bool;
  debug_generation : int;
}

type 'a refresh_plan = {
  refresh_value : 'a option;
  refresh_next_due_ms : int option;
  refresh_finish : bool;
}

type _ refresh_spec =
  | Refresh_current_time : int refresh_spec
  | Refresh_deadline : int -> bool refresh_spec
  | Refresh_interval : int -> int refresh_spec

type 'a source_policy = {
  source_update_on_start : bool;
  source_catch_up_policy : catch_up_policy;
  source_refresh_when_inactive : bool;
  source_refresh_on_demand : 'a refresh_spec option;
}

type demand_action =
  | Demand_none
  | Demand_start
  | Demand_stop

type 'a demand_item = {
  demand_item : 'a;
  demand_necessary : bool;
  demand_effective_state : state;
  demand_current_state : state;
}

type ('id, 'timer) demand_resource

type daemon_status =
  | Daemon_continue
  | Daemon_stop

type daemon_exit =
  | Daemon_ok
  | Daemon_error

type wake_plan = {
  wake_next_due_ms : int;
  wake_saturated_due : bool;
  wake_update_count : int;
  wake_update_missed : int;
}

type update_batch = {
  update_batch_count : int;
  update_batch_remaining : int;
  update_batch_yield : bool;
}

type stop_plan = {
  stop_state : state;
  stop_cancel_hooks : (unit -> unit) list;
}

type start_plan = {
  start_state : state;
  start_generation : int;
}

type ('id, 'timer, 'start, 'hook, 'error) demand_context = {
  demand_resource_necessary : 'id -> bool;
  demand_resource_validate : 'timer -> (unit, 'error) result;
  demand_resource_effective_state : 'timer -> state;
  demand_resource_current_state : 'timer -> state;
  demand_plan_start : 'timer -> start_plan -> 'start;
  demand_plan_stop : 'timer -> stop_plan -> 'hook list;
}

type 'a demand_plan =
  | Demand_plan_start of 'a * start_plan
  | Demand_plan_stop of 'a * stop_plan option

type ('start, 'hook) demand_effects

type finish_plan = {
  finish_state : state;
  finish_cancel_hooks : (unit -> unit) list;
}

type 'a refresh_action =
  | Refresh_set of 'a
  | Refresh_advance_due of int
  | Refresh_finish of finish_plan

type advance_next_due_action =
  | Advance_next_due_stop
  | Advance_next_due_stale
  | Advance_next_due_update of state

val add_ms_capped : int -> int -> int
val mul_ms_capped : int -> int -> int
val add_int_capped : int -> int -> int
val missed_cadences : interval_ms:int -> next_due_ms:int -> now_ms:int -> int
val advance_due : int -> int -> int -> int
val initial_next_due_ms : now_ms:int -> interval_ms:int -> int
val sleep_delay_ms : now_ms:int -> next_due_ms:int -> int

val add_relative_deadline :
  int -> int -> (int, [> `Deadline_overflow | `Past_deadline ]) result

val validate_interval_ms : int -> (unit, [> `Invalid_interval ]) result

val validate_future_deadline :
  now_ms:int -> deadline_ms:int -> (unit, [> `Past_deadline ]) result

val validate_positive_duration_ms : int -> (unit, [> `Past_deadline ]) result

val validate_runtime :
  same_runtime:('runtime -> 'runtime -> bool) ->
  expected:'runtime ->
  actual:'runtime ->
  (unit, [> `Runtime_mismatch ]) result

val current_time_source_policy : unit -> int source_policy
val deadline_source_policy : deadline_ms:int -> bool source_policy
val interval_source_policy : interval_ms:int -> int source_policy
val step_source_policy : unit -> 'a source_policy
val step_replay_source_policy : unit -> 'a source_policy

val catch_up_update_count : catch_up_policy -> int -> int
val catch_up_update_missed : catch_up_policy -> int -> int

val update_batch : remaining:int -> update_batch option

val daemon_wake_plan :
  catch_up_policy:catch_up_policy ->
  interval_ms:int ->
  next_due_ms:int ->
  now_ms:int ->
  wake_plan

val state_generation : state -> int
val state_with_generation : state -> int -> state
val inactive_state : generation:int -> state
val starting_state : generation:int -> state
val running_uncancellable_state : generation:int -> next_due_ms:int option -> state
val running_state :
  generation:int -> next_due_ms:int option -> cancel:(unit -> unit) -> state

val finished_state : generation:int -> state

val snapshot :
  state:state -> on_demand_refresh_token:int -> snapshot

val initial_snapshot : snapshot
val snapshot_state : snapshot -> state
val snapshot_on_demand_refresh_token : snapshot -> int
val snapshot_with_state : snapshot -> state -> snapshot
val snapshot_with_generation : snapshot -> int -> snapshot
val snapshot_with_on_demand_refresh_token : snapshot -> int -> snapshot
val snapshot_with_next_due : snapshot -> int -> snapshot option

val create_refresh_context :
  token:int ->
  runtime_contract:'runtime ->
  now_ms:(unit -> int) ->
  ('runtime, 'dirty) refresh_context

val refresh_token : ('runtime, 'dirty) refresh_context -> int

val refresh_runtime_contract :
  ('runtime, 'dirty) refresh_context -> 'runtime

val refresh_sample_now_ms : ('runtime, 'dirty) refresh_context -> int
val refresh_dirty_items : (_, 'dirty) refresh_context -> 'dirty list
val set_refresh_dirty_items : (_, 'dirty) refresh_context -> 'dirty list -> unit
val clear_refresh_dirty_items : (_, 'dirty) refresh_context -> unit

val state_label : state -> string
val state_starting : state -> bool
val state_active : state -> bool
val state_finished : state -> bool
val state_has_current_start : state -> bool
val state_running_generation : state -> int option
val state_has_cancel : state -> bool
val state_running_current : state -> int -> bool
val state_next_due : state -> int option
val state_set_next_due : state -> int option -> state
val debug_snapshot : state -> debug_snapshot

val daemon_status : state -> generation:int -> daemon_status

val needs_start : effective_state:state -> current_state:state -> bool
val needs_stop : effective_state:state -> bool

val demand_action :
  necessary:bool -> effective_state:state -> current_state:state -> demand_action

val demand_resource : id:'id -> 'timer -> ('id, 'timer) demand_resource

val classify_demand :
  ('id, 'timer, _, _, 'error) demand_context ->
  ('id, 'timer) demand_resource list ->
  ('timer demand_item list, 'error) result

val start :
  advance_generation:(int -> int) ->
  effective_state:state ->
  current_state:state ->
  start_plan option

val preflight_start :
  advance_generation:(int -> int) ->
  effective_state:state ->
  current_state:state ->
  unit

val preflight_stop :
  advance_generation:(int -> int) ->
  effective_state:state ->
  current_state:state ->
  unit

val demand_plans :
  advance_generation:(int -> int) ->
  cancel_running:bool ->
  'a demand_item list ->
  'a demand_plan list

val apply_demand_plans :
  start:('timer -> start_plan -> 'start) ->
  stop:('timer -> stop_plan -> 'hook list) ->
  'timer demand_plan list ->
  ('start, 'hook) demand_effects

val demand_effects_result :
  ('start, 'hook) demand_effects ->
  plan:(start_attempts:'start list -> cancel_hooks:'hook list -> 'a) ->
  'a

val demand_effects :
  advance_generation:(int -> int) ->
  cancel_running:bool ->
  ('id, 'timer, 'start, 'hook, 'error) demand_context ->
  ('id, 'timer) demand_resource list ->
  (('start, 'hook) demand_effects, 'error) result

val begin_start : state -> generation:int -> state option

val install_cancel :
  state -> generation:int -> cancel:(unit -> unit) -> state option

val mark_stopped : state -> generation:int -> state option

val mark_failed :
  advance_generation:(int -> int) ->
  effective_state:state ->
  current_state:state ->
  generation:int ->
  state option

val cleanup_after_exit :
  advance_generation:(int -> int) ->
  effective_state:state ->
  current_state:state ->
  generation:int ->
  daemon_exit ->
  state option

val cleanup_failed_start :
  advance_generation:(int -> int) ->
  effective_state:state ->
  current_state:state ->
  generation:int ->
  daemon_exit ->
  state option

val finish_current_daemon :
  advance_generation:(int -> int) ->
  effective_state:state ->
  current_state:state ->
  generation:int ->
  state option

val read_next_due : state -> generation:int -> fallback:int -> int option

val set_next_due :
  effective_state:state ->
  current_state:state ->
  generation:int ->
  next_due_ms:int ->
  state option

val advance_next_due :
  effective_state:state ->
  current_state:state ->
  generation:int ->
  expected:int ->
  next_due_ms:int ->
  advance_next_due_action

val stop :
  advance_generation:(int -> int) ->
  cancel_running:bool ->
  state ->
  stop_plan option

val can_refresh_on_demand :
  refresh_operation:bool ->
  current_token:int ->
  staged_token:int ->
  token:int ->
  refresh_when_inactive:bool ->
  active:bool ->
  finished:bool ->
  bool

val finish : advance_generation:(int -> int) -> state -> finish_plan
val current_time_refresh_plan : now_ms:int -> int refresh_plan
val refresh_actions :
  advance_generation:(int -> int) ->
  state:state ->
  'a refresh_plan ->
  'a refresh_action list

val refresh_actions_for_spec :
  advance_generation:(int -> int) ->
  state:state ->
  current_value:'a ->
  now_ms:int ->
  'a refresh_spec ->
  'a refresh_action list

val refresh_plan_for_spec :
  state:state ->
  current_value:'a ->
  now_ms:int ->
  'a refresh_spec ->
  'a refresh_plan

val deadline_refresh_plan :
  now_ms:int -> deadline_ms:int -> bool refresh_plan

val interval_refresh_plan :
  state:state ->
  interval_ms:int ->
  current_value:int ->
  now_ms:int ->
  int refresh_plan
