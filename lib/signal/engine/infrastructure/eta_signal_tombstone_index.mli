(** Bounded tombstone-index instrumentation. *)

type counters

type counter_snapshot = {
  slot_writes : int;
  evictions : int;
  iteration_visits : int;
  duplicate_scan_steps : int;
}

val create_counters : unit -> counters
val reset_counters : counters -> unit
val disable_counters : counters -> unit
val counter_snapshot : counters -> counter_snapshot
val note_slot_write : counters -> unit
val note_eviction : counters -> unit
val note_iteration_visit : counters -> unit
val note_duplicate_scan_step : counters -> unit
