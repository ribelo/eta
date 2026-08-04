(** Graph-branded access to private test state.

    The graph owner supplies operations that already hold its lane. The phantom
    graph type prevents a probe from inspecting another functor application. *)

type ('graph, 'snapshot, 'fault, 'census) t

val create :
  reset:(unit -> unit) ->
  snapshot:(unit -> 'snapshot) ->
  set_fault:('fault option -> unit) ->
  census:(unit -> 'census) ->
  ('graph, 'snapshot, 'fault, 'census) t

val reset : (_, _, _, _) t -> unit
val snapshot : (_, 'snapshot, _, _) t -> 'snapshot
val set_fault : (_, _, 'fault, _) t -> 'fault option -> unit
val census : (_, _, _, 'census) t -> 'census
