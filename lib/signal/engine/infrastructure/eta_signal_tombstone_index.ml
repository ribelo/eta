type counters = {
  mutable enabled : bool;
  mutable slot_writes : int;
  mutable evictions : int;
  mutable iteration_visits : int;
  mutable duplicate_scan_steps : int;
}

type counter_snapshot = {
  slot_writes : int;
  evictions : int;
  iteration_visits : int;
  duplicate_scan_steps : int;
}

let create_counters () =
  {
    enabled = false;
    slot_writes = 0;
    evictions = 0;
    iteration_visits = 0;
    duplicate_scan_steps = 0;
  }

let reset_counters counters =
  counters.enabled <- true;
  counters.slot_writes <- 0;
  counters.evictions <- 0;
  counters.iteration_visits <- 0;
  counters.duplicate_scan_steps <- 0

let disable_counters counters = counters.enabled <- false

let counter_snapshot (counters : counters) =
  {
    slot_writes = counters.slot_writes;
    evictions = counters.evictions;
    iteration_visits = counters.iteration_visits;
    duplicate_scan_steps = counters.duplicate_scan_steps;
  }

let succ value = if value = max_int then max_int else value + 1

let note_slot_write counters =
  if counters.enabled then counters.slot_writes <- succ counters.slot_writes

let note_eviction counters =
  if counters.enabled then counters.evictions <- succ counters.evictions

let note_iteration_visit counters =
  if counters.enabled then
    counters.iteration_visits <- succ counters.iteration_visits

let note_duplicate_scan_step counters =
  if counters.enabled then
    counters.duplicate_scan_steps <- succ counters.duplicate_scan_steps
