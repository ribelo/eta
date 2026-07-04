(** Pure timer policy helpers for Eta_signal internals. *)

type catch_up_policy =
  | Catch_up_every_cadence
  | Catch_up_once_per_wake
  | Catch_up_coalesced

val add_ms_capped : int -> int -> int
val mul_ms_capped : int -> int -> int
val add_int_capped : int -> int -> int
val missed_cadences : interval_ms:int -> next_due_ms:int -> now_ms:int -> int
val advance_due : int -> int -> int -> int

val add_relative_deadline :
  int -> int -> (int, [> `Deadline_overflow | `Past_deadline ]) result

val catch_up_update_count : catch_up_policy -> int -> int
val catch_up_update_missed : catch_up_policy -> int -> int
