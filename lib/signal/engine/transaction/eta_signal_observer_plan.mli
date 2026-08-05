(** Deterministic topological observer planning and instrumentation. *)

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

type ('observer, 'node) access

val access :
  node_id:('node -> int) ->
  dependencies:('node -> 'node list) ->
  observer_id:('observer -> int) ->
  observed:('observer -> 'node) ->
  ('observer, 'node) access
(** Graph access used by the planner. [dependencies] must describe the final
    prospective topology for the current stabilization. *)

val plan :
  counters ->
  ('observer, 'node) access ->
  cycle:(unit -> 'observer list) ->
  'observer list ->
  'observer list
(** Return the unique candidate observers in one deterministic topological
    total order. Dependencies precede transitive consumers, observers on one
    signal use observer identity, and ready unrelated groups use their smallest
    observer identity. The traversal performs no pairwise reachability search.
    [cycle] is called when the prospective union is cyclic. *)
