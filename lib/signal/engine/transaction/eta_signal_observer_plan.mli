(** Deterministic observer-plan instrumentation. *)

type counters

type counter_snapshot = {
  candidate_visits : int;
  union_node_visits : int;
  union_edge_visits : int;
  ready_pushes : int;
  ready_pops : int;
  ready_comparisons : int;
  pairwise_search_visits : int;
}

val create_counters : unit -> counters
val reset_counters : counters -> unit
val disable_counters : counters -> unit
val counter_snapshot : counters -> counter_snapshot
val note_candidate_visit : counters -> unit
val note_union_node_visit : counters -> unit
val note_union_edge_visit : counters -> unit
val note_ready_push : counters -> unit
val note_ready_pop : counters -> unit
val note_ready_comparison : counters -> unit
val note_pairwise_search_visit : counters -> unit
