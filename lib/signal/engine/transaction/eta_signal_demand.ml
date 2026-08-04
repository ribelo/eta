type counters = {
  mutable enabled : bool;
  mutable reference_operations : int;
  mutable zero_boundaries : int;
  mutable dependency_edge_visits : int;
  mutable timer_desired_state_transitions : int;
}

type counter_snapshot = {
  reference_operations : int;
  zero_boundaries : int;
  dependency_edge_visits : int;
  timer_desired_state_transitions : int;
}

let create_counters () =
  {
    enabled = false;
    reference_operations = 0;
    zero_boundaries = 0;
    dependency_edge_visits = 0;
    timer_desired_state_transitions = 0;
  }

let reset_counters counters =
  counters.enabled <- true;
  counters.reference_operations <- 0;
  counters.zero_boundaries <- 0;
  counters.dependency_edge_visits <- 0;
  counters.timer_desired_state_transitions <- 0

let disable_counters counters = counters.enabled <- false

let counter_snapshot (counters : counters) =
  {
    reference_operations = counters.reference_operations;
    zero_boundaries = counters.zero_boundaries;
    dependency_edge_visits = counters.dependency_edge_visits;
    timer_desired_state_transitions =
      counters.timer_desired_state_transitions;
  }

let succ value = if value = max_int then max_int else value + 1

let note_reference_operation counters =
  if counters.enabled then
    counters.reference_operations <- succ counters.reference_operations

let note_zero_boundary counters =
  if counters.enabled then
    counters.zero_boundaries <- succ counters.zero_boundaries

let note_dependency_edge_visit counters =
  if counters.enabled then
    counters.dependency_edge_visits <- succ counters.dependency_edge_visits

let note_timer_desired_state_transition counters =
  if counters.enabled then
    counters.timer_desired_state_transitions <-
      succ counters.timer_desired_state_transitions
