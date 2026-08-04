(** Incremental-demand instrumentation. *)

type counters

type counter_snapshot = {
  reference_operations : int;
  zero_boundaries : int;
  dependency_edge_visits : int;
  timer_desired_state_transitions : int;
}

val create_counters : unit -> counters
val reset_counters : counters -> unit
val disable_counters : counters -> unit
val counter_snapshot : counters -> counter_snapshot
val note_reference_operation : counters -> unit
val note_zero_boundary : counters -> unit
val note_dependency_edge_visit : counters -> unit
val note_timer_desired_state_transition : counters -> unit
