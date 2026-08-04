(** Phase authority and deterministic planning fault slots. *)

type fault_slot =
  | Before_phase_install
  | After_phase_install
  | After_dynamic_discovery
  | After_frontier_freeze
  | After_discard_partition
  | After_prospective_validation
  | Before_plan_seal
  | Before_total_commit

type counters

type counter_snapshot = {
  phase_entries : int;
  commits : int;
  rollback_calls : int;
  returns_to_idle : int;
}

val create_counters : unit -> counters
val reset_counters : counters -> unit
val disable_counters : counters -> unit
val counter_snapshot : counters -> counter_snapshot
val note_phase_entry : counters -> unit
val note_commit : counters -> unit
val note_rollback : counters -> unit
val note_return_to_idle : counters -> unit

type fault = {
  slot : fault_slot;
  exn : exn;
}

type fault_injector

val create_fault_injector : unit -> fault_injector
val set_fault : fault_injector -> fault option -> unit
val check_fault : fault_injector -> fault_slot -> unit
