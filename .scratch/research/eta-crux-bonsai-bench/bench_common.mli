type counters = {
  actions : int;
  transitions : int;
  driver_cycles : int;
  observations : int;
  projections : int;
  child_visits : int;
  changed_rows : int;
}

val zero : counters
val add : counters -> counters -> counters

type instance = {
  expected_per_operation : counters;
  snapshot : unit -> counters;
  isolated_operations : bool;
  set_full_validation : bool -> unit;
  prepare_batch : unit -> unit;
  run_batch : operations:int -> unit;
  finish_batch : unit -> unit;
  teardown : unit -> unit;
}

type workload

val workload : string -> (unit -> instance) -> workload
val main : framework:string -> workload list -> unit
