(** Necessary-stale scheduler instrumentation. *)

type counters

type counter_snapshot = {
  admissions : int;
  claims : int;
  dependency_edge_visits : int;
  propagation_edge_visits : int;
  node_evaluations : int;
  cutoff_calls : int;
}

val create_counters : unit -> counters
val reset_counters : counters -> unit
val disable_counters : counters -> unit
val counter_snapshot : counters -> counter_snapshot
val note_admission : counters -> unit
val note_claim : counters -> unit
val note_dependency_edge_visit : counters -> unit
val note_propagation_edge_visit : counters -> unit
val note_node_evaluation : counters -> unit
val note_cutoff_call : counters -> unit

type ('node, 'next) access

type 'next t

val access :
  queued:('node -> bool) ->
  set_queued:('node -> bool -> unit) ->
  previous:('node -> 'next option) ->
  set_previous:('node -> 'next option -> unit) ->
  next:('node -> 'next option) ->
  set_next:('node -> 'next option -> unit) ->
  attempt_local:('node -> bool) ->
  set_attempt_local:('node -> bool -> unit) ->
  attempt_removed:('node -> bool) ->
  set_attempt_removed:('node -> bool -> unit) ->
  pack:('node -> 'next) ->
  unpack:('next -> 'node) ->
  ('node, 'next) access

val create : counters -> 'next t
val is_empty : 'next t -> bool
val attempt_active : 'next t -> bool
val begin_attempt : 'next t -> unit
val admit : 'next t -> ('node, 'next) access -> 'node -> bool
val claim : 'next t -> ('node, 'next) access -> 'node option
val remove : 'next t -> ('node, 'next) access -> 'node -> bool
val commit_attempt : 'next t -> ('node, 'next) access -> int
val rollback_attempt : 'next t -> ('node, 'next) access -> int
