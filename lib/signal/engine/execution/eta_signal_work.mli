(** O(1) graph-work admission instrumentation. *)

type counters

type counter_snapshot = {
  admission_checks : int;
  quiescent_returns : int;
  work_class_zero_crossings : int;
}

val create_counters : unit -> counters
val reset_counters : counters -> unit
val disable_counters : counters -> unit
val counter_snapshot : counters -> counter_snapshot
val note_admission_check : counters -> unit
val note_quiescent_return : counters -> unit
val note_work_class_zero_crossing : counters -> unit

type class_ =
  | Sources
  | Scheduler
  | Observer_delivery
  | Timer_reconciliation
  | Cleanup

type t

val create : counters -> t
val total : t -> int
val quiescent : t -> bool
val count : t -> class_ -> int
val admit : t -> class_ -> unit
val release : t -> class_ -> unit
val note_quiescent : t -> unit

val check_quiescent : t -> bool
