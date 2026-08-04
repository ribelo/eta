type fault_slot =
  | Before_phase_install
  | After_phase_install
  | After_dynamic_discovery
  | After_frontier_freeze
  | After_discard_partition
  | After_prospective_validation
  | Before_plan_seal
  | Before_total_commit

type counters = {
  mutable enabled : bool;
  mutable phase_entries : int;
  mutable commits : int;
  mutable rollback_calls : int;
  mutable returns_to_idle : int;
}

type counter_snapshot = {
  phase_entries : int;
  commits : int;
  rollback_calls : int;
  returns_to_idle : int;
}

let create_counters () =
  {
    enabled = false;
    phase_entries = 0;
    commits = 0;
    rollback_calls = 0;
    returns_to_idle = 0;
  }

let reset_counters counters =
  counters.enabled <- true;
  counters.phase_entries <- 0;
  counters.commits <- 0;
  counters.rollback_calls <- 0;
  counters.returns_to_idle <- 0

let disable_counters counters = counters.enabled <- false

let counter_snapshot (counters : counters) =
  {
    phase_entries = counters.phase_entries;
    commits = counters.commits;
    rollback_calls = counters.rollback_calls;
    returns_to_idle = counters.returns_to_idle;
  }

let succ value = if value = max_int then max_int else value + 1

let note_phase_entry counters =
  if counters.enabled then
    counters.phase_entries <- succ counters.phase_entries

let note_commit counters =
  if counters.enabled then counters.commits <- succ counters.commits

let note_rollback counters =
  if counters.enabled then
    counters.rollback_calls <- succ counters.rollback_calls

let note_return_to_idle counters =
  if counters.enabled then
    counters.returns_to_idle <- succ counters.returns_to_idle

type fault = {
  slot : fault_slot;
  exn : exn;
}

type fault_injector = { mutable fault : fault option }

let create_fault_injector () = { fault = None }
let set_fault injector fault = injector.fault <- fault

let check_fault injector slot =
  match injector.fault with
  | Some fault when fault.slot = slot -> raise fault.exn
  | Some _ | None -> ()
