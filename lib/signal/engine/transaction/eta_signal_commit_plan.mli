type counters
type counter_snapshot = {
  sealed_plans : int;
  prepared_writes : int;
  applied_writes : int;
  cycle_nodes : int;
  cycle_edges : int;
}

val create_counters : unit -> counters
val reset_counters : counters -> unit
val disable_counters : counters -> unit
val counter_snapshot : counters -> counter_snapshot
val note_sealed_plan : counters -> unit
val note_prepared_write : counters -> unit
val note_applied_write : counters -> unit
val note_cycle_node : counters -> unit
val note_cycle_edge : counters -> unit

type open_
type sealed
type ('phase, 'hook) t

val create : counters -> (open_, 'hook) t
val add_write : (open_, 'hook) t -> (unit -> 'hook list) -> unit
val seal : (open_, 'hook) t -> (sealed, 'hook) t
val apply : (sealed, 'hook) t -> 'hook list
(** Apply only prepared engine writes. This operation is total by construction. *)
