type counters = {
  mutable enabled : bool;
  mutable admissions : int;
  mutable claims : int;
  mutable dependency_edge_visits : int;
  mutable propagation_edge_visits : int;
  mutable node_evaluations : int;
  mutable cutoff_calls : int;
}

type counter_snapshot = {
  admissions : int;
  claims : int;
  dependency_edge_visits : int;
  propagation_edge_visits : int;
  node_evaluations : int;
  cutoff_calls : int;
}

let create_counters () =
  {
    enabled = false;
    admissions = 0;
    claims = 0;
    dependency_edge_visits = 0;
    propagation_edge_visits = 0;
    node_evaluations = 0;
    cutoff_calls = 0;
  }

let reset_counters counters =
  counters.enabled <- true;
  counters.admissions <- 0;
  counters.claims <- 0;
  counters.dependency_edge_visits <- 0;
  counters.propagation_edge_visits <- 0;
  counters.node_evaluations <- 0;
  counters.cutoff_calls <- 0

let disable_counters counters = counters.enabled <- false

let counter_snapshot (counters : counters) =
  {
    admissions = counters.admissions;
    claims = counters.claims;
    dependency_edge_visits = counters.dependency_edge_visits;
    propagation_edge_visits = counters.propagation_edge_visits;
    node_evaluations = counters.node_evaluations;
    cutoff_calls = counters.cutoff_calls;
  }

let succ value = if value = max_int then max_int else value + 1

let note_admission counters =
  if counters.enabled then counters.admissions <- succ counters.admissions

let note_claim counters =
  if counters.enabled then counters.claims <- succ counters.claims

let note_dependency_edge_visit counters =
  if counters.enabled then
    counters.dependency_edge_visits <- succ counters.dependency_edge_visits

let note_propagation_edge_visit counters =
  if counters.enabled then
    counters.propagation_edge_visits <- succ counters.propagation_edge_visits

let note_node_evaluation counters =
  if counters.enabled then
    counters.node_evaluations <- succ counters.node_evaluations

let note_cutoff_call counters =
  if counters.enabled then counters.cutoff_calls <- succ counters.cutoff_calls
