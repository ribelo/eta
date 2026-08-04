type counters = {
  mutable enabled : bool;
  mutable candidate_visits : int;
  mutable union_node_visits : int;
  mutable union_edge_visits : int;
  mutable ready_pushes : int;
  mutable ready_pops : int;
  mutable ready_comparisons : int;
  mutable pairwise_search_visits : int;
}

type counter_snapshot = {
  candidate_visits : int;
  union_node_visits : int;
  union_edge_visits : int;
  ready_pushes : int;
  ready_pops : int;
  ready_comparisons : int;
  pairwise_search_visits : int;
}

let create_counters () =
  {
    enabled = false;
    candidate_visits = 0;
    union_node_visits = 0;
    union_edge_visits = 0;
    ready_pushes = 0;
    ready_pops = 0;
    ready_comparisons = 0;
    pairwise_search_visits = 0;
  }

let reset_counters counters =
  counters.enabled <- true;
  counters.candidate_visits <- 0;
  counters.union_node_visits <- 0;
  counters.union_edge_visits <- 0;
  counters.ready_pushes <- 0;
  counters.ready_pops <- 0;
  counters.ready_comparisons <- 0;
  counters.pairwise_search_visits <- 0

let disable_counters counters = counters.enabled <- false

let counter_snapshot (counters : counters) =
  {
    candidate_visits = counters.candidate_visits;
    union_node_visits = counters.union_node_visits;
    union_edge_visits = counters.union_edge_visits;
    ready_pushes = counters.ready_pushes;
    ready_pops = counters.ready_pops;
    ready_comparisons = counters.ready_comparisons;
    pairwise_search_visits = counters.pairwise_search_visits;
  }

let succ value = if value = max_int then max_int else value + 1

let note_candidate_visit counters =
  if counters.enabled then
    counters.candidate_visits <- succ counters.candidate_visits

let note_union_node_visit counters =
  if counters.enabled then
    counters.union_node_visits <- succ counters.union_node_visits

let note_union_edge_visit counters =
  if counters.enabled then
    counters.union_edge_visits <- succ counters.union_edge_visits

let note_ready_push counters =
  if counters.enabled then counters.ready_pushes <- succ counters.ready_pushes

let note_ready_pop counters =
  if counters.enabled then counters.ready_pops <- succ counters.ready_pops

let note_ready_comparison counters =
  if counters.enabled then
    counters.ready_comparisons <- succ counters.ready_comparisons

let note_pairwise_search_visit counters =
  if counters.enabled then
    counters.pairwise_search_visits <- succ counters.pairwise_search_visits
