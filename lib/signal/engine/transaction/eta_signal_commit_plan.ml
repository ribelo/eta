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

let note update counters =
  if counters.enabled then update counters

let note_sealed_plan counters =
  note (fun counters -> counters.sealed_plans <- succ counters.sealed_plans) counters

let note_prepared_write counters =
  note
    (fun counters -> counters.prepared_writes <- succ counters.prepared_writes)
    counters

let note_applied_write counters =
  note
    (fun counters -> counters.applied_writes <- succ counters.applied_writes)
    counters

let note_cycle_node counters =
  note (fun counters -> counters.cycle_nodes <- succ counters.cycle_nodes) counters

let note_cycle_edge counters =
  note (fun counters -> counters.cycle_edges <- succ counters.cycle_edges) counters

type open_
type sealed

type 'hook write = unit -> 'hook list

type ('phase, 'hook) t = {
  counters : counters;
  mutable writes : 'hook write list;
  mutable sealed : bool;
}

let create counters = { counters; writes = []; sealed = false }

let add_write plan write =
  if plan.sealed then invalid_arg "Eta_signal_commit_plan.add_write: sealed plan";
  plan.writes <- write :: plan.writes;
  note_prepared_write plan.counters

let seal plan =
  if plan.sealed then invalid_arg "Eta_signal_commit_plan.seal: sealed plan";
  plan.sealed <- true;
  plan.writes <- List.rev plan.writes;
  note_sealed_plan plan.counters;
  { counters = plan.counters; writes = plan.writes; sealed = true }

let apply plan =
  let rec loop hooks = function
    | [] -> List.rev hooks |> List.concat
    | write :: rest ->
        let produced = write () in
        note_applied_write plan.counters;
        loop (produced :: hooks) rest
  in
  loop [] plan.writes
