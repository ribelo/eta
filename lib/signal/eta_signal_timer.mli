(** Pure timer policy helpers for Eta_signal internals. *)

type catch_up_policy =
  | Catch_up_every_cadence
  | Catch_up_once_per_wake
  | Catch_up_coalesced

type state =
  | Timer_inactive of int
  | Timer_starting of int
  | Timer_running_uncancellable of int * int option
  | Timer_running of int * int option * (unit -> unit)
  | Timer_finished of int

type due_refresh = {
  missed : int;
  saturated_due : bool;
  next_due_ms : int option;
}

type deadline_refresh = {
  deadline_value : bool;
  deadline_finish : bool;
}

type interval_refresh = {
  interval_value : int option;
  interval_next_due_ms : int option;
  interval_finish : bool;
}

type demand_action =
  | Demand_none
  | Demand_start
  | Demand_stop

type stop_plan = {
  stop_state : state;
  stop_cancel_hooks : (unit -> unit) list;
}

type start_plan = {
  start_state : state;
  start_generation : int;
}

val add_ms_capped : int -> int -> int
val mul_ms_capped : int -> int -> int
val add_int_capped : int -> int -> int
val missed_cadences : interval_ms:int -> next_due_ms:int -> now_ms:int -> int
val advance_due : int -> int -> int -> int

val add_relative_deadline :
  int -> int -> (int, [> `Deadline_overflow | `Past_deadline ]) result

val catch_up_update_count : catch_up_policy -> int -> int
val catch_up_update_missed : catch_up_policy -> int -> int
val state_generation : state -> int
val state_with_generation : state -> int -> state
val state_label : state -> string
val state_active : state -> bool
val state_finished : state -> bool
val state_has_current_start : state -> bool
val state_running_generation : state -> int option
val state_has_cancel : state -> bool
val state_running_current : state -> int -> bool
val state_next_due : state -> int option
val state_set_next_due : state -> int option -> state

val needs_start : effective_state:state -> current_state:state -> bool
val needs_stop : effective_state:state -> bool

val demand_action :
  necessary:bool -> effective_state:state -> current_state:state -> demand_action

val start :
  advance_generation:(int -> int) ->
  effective_state:state ->
  current_state:state ->
  start_plan option

val begin_start : state -> generation:int -> state option

val install_cancel :
  state -> generation:int -> cancel:(unit -> unit) -> state option

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

val finish_state : advance_generation:(int -> int) -> state -> state
val finish_cancel_hooks : state -> (unit -> unit) list
val due_refresh : state -> interval_ms:int -> now_ms:int -> due_refresh
val deadline_refresh : now_ms:int -> deadline_ms:int -> deadline_refresh

val interval_refresh :
  state:state ->
  interval_ms:int ->
  current_value:int ->
  now_ms:int ->
  interval_refresh
