(** Necessary-stale scheduler instrumentation. *)

type counters

type counter_snapshot = {
  admissions : int;
  claims : int;
  dependency_edge_visits : int;
  propagation_edge_visits : int;
  node_evaluations : int;
  cutoff_calls : int;
}

val create_counters : unit -> counters
val reset_counters : counters -> unit
val disable_counters : counters -> unit
val counter_snapshot : counters -> counter_snapshot
val note_admission : counters -> unit
val note_claim : counters -> unit
val note_dependency_edge_visit : counters -> unit
val note_propagation_edge_visit : counters -> unit
val note_node_evaluation : counters -> unit
val note_cutoff_call : counters -> unit
