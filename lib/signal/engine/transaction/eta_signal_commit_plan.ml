type counters = {
  mutable enabled : bool;
  mutable sealed_plans : int;
  mutable prepared_writes : int;
  mutable applied_writes : int;
  mutable cycle_nodes : int;
  mutable cycle_edges : int;
}

type counter_snapshot = {
  sealed_plans : int;
  prepared_writes : int;
  applied_writes : int;
  cycle_nodes : int;
  cycle_edges : int;
}

let create_counters () =
  {
    enabled = false;
    sealed_plans = 0;
    prepared_writes = 0;
    applied_writes = 0;
    cycle_nodes = 0;
    cycle_edges = 0;
  }

let reset_counters counters =
  counters.enabled <- true;
  counters.sealed_plans <- 0;
  counters.prepared_writes <- 0;
  counters.applied_writes <- 0;
  counters.cycle_nodes <- 0;
  counters.cycle_edges <- 0

let disable_counters counters = counters.enabled <- false

let counter_snapshot (counters : counters) =
  {
    sealed_plans = counters.sealed_plans;
    prepared_writes = counters.prepared_writes;
    applied_writes = counters.applied_writes;
    cycle_nodes = counters.cycle_nodes;
    cycle_edges = counters.cycle_edges;
  }

let succ value = if value = max_int then max_int else value + 1

let note_sealed_plan counters =
  if counters.enabled then counters.sealed_plans <- succ counters.sealed_plans

let note_prepared_write counters =
  if counters.enabled then
    counters.prepared_writes <- succ counters.prepared_writes

let note_applied_write counters =
  if counters.enabled then
    counters.applied_writes <- succ counters.applied_writes

let note_cycle_node counters =
  if counters.enabled then counters.cycle_nodes <- succ counters.cycle_nodes

let note_cycle_edge counters =
  if counters.enabled then counters.cycle_edges <- succ counters.cycle_edges
