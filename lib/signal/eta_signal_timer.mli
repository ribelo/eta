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
