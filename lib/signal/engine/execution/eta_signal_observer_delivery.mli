(** Observer-delivery instrumentation. *)

type counters

type counter_snapshot = {
  lifecycle_checks : int;
  callback_attempts : int;
  acknowledgement_attempts : int;
  acknowledgement_successes : int;
  releases : int;
  terminal_skips : int;
}

val create_counters : unit -> counters
val reset_counters : counters -> unit
val disable_counters : counters -> unit
val counter_snapshot : counters -> counter_snapshot
val note_lifecycle_check : counters -> unit
val note_callback_attempt : counters -> unit
val note_acknowledgement_attempt : counters -> unit
val note_acknowledgement_success : counters -> unit
val note_release : counters -> unit
val note_terminal_skip : counters -> unit
