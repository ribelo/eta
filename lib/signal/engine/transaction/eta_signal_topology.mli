(** Indexed-topology instrumentation. *)

type counters

type counter_snapshot = {
  static_inserts : int;
  dynamic_inserts : int;
  indexed_removals : int;
  slot_repairs : int;
  invalidated_nodes : int;
  adjacency_search_steps : int;
}

val create_counters : unit -> counters
val reset_counters : counters -> unit
val disable_counters : counters -> unit
val counter_snapshot : counters -> counter_snapshot
val note_static_insert : counters -> unit
val note_dynamic_insert : counters -> unit
val note_indexed_removal : counters -> unit
val note_slot_repair : counters -> unit
val note_invalidated_node : counters -> unit
val note_adjacency_search_step : counters -> unit
