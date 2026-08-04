(** Stable-family edit instrumentation. *)

type counters

type counter_snapshot = {
  input_comparisons : int;
  diff_events : int;
  selected_child_visits : int;
  provisional_additions : int;
  commits : int;
  discards : int;
}

val create_counters : unit -> counters
val reset_counters : counters -> unit
val disable_counters : counters -> unit
val counter_snapshot : counters -> counter_snapshot
val note_input_comparison : counters -> unit
val note_diff_event : counters -> unit
val note_selected_child_visit : counters -> unit
val note_provisional_addition : counters -> unit
val note_commit : counters -> unit
val note_discard : counters -> unit
