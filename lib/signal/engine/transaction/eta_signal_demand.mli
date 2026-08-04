(** Incremental-demand instrumentation. *)

type counters

type counter_snapshot = {
  reference_operations : int;
  zero_boundaries : int;
  dependency_edge_visits : int;
  timer_desired_state_transitions : int;
}

val create_counters : unit -> counters
val reset_counters : counters -> unit
val disable_counters : counters -> unit
val counter_snapshot : counters -> counter_snapshot
val note_reference_operation : counters -> unit
val note_zero_boundary : counters -> unit
val note_dependency_edge_visit : counters -> unit
val note_timer_desired_state_transition : counters -> unit

type ('node, 'edge) ops

val ops :
  demand:('node -> int) ->
  set_demand:('node -> int -> unit) ->
  iter_dependencies:('node -> ('edge -> unit) -> unit) ->
  dependency:('edge -> 'node) ->
  on_boundary:('node -> necessary:bool -> unit) ->
  ('node, 'edge) ops

val adjust :
  counters ->
  ('node, 'edge) ops ->
  'node ->
  int ->
  (unit, [ `Overflow | `Underflow ]) result

val adjust_many :
  counters ->
  ('node, 'edge) ops ->
  'node list ->
  int ->
  (unit, [ `Overflow | `Underflow ]) result

val check :
  ('node, 'edge) ops ->
  'node ->
  int ->
  (unit, [ `Overflow | `Underflow ]) result
