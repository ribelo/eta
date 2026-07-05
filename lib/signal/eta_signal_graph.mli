(** Graph container for Eta_signal internals.

    This module owns construction of the graph-owned runtime state and the
    mutable registries that track observers, weak live nodes, and dead-node
    tombstones. Lower-level subsystem handles remain exposed while compute and
    stabilization are still being migrated behind this seam. *)

type
  ( 'pending,
    'bind,
    'node,
    'hook,
    'timer,
    'refresh,
    'observer,
    'weak_node,
    'dead_node,
    'scope_context,
    'stream_metrics )
  t

val create :
  create_scope_context:(unit -> 'scope_context) ->
  create_stream_bridge_metrics:(unit -> 'stream_metrics) ->
  unit ->
  ( 'pending,
    'bind,
    'node,
    'hook,
    'timer,
    'refresh,
    'observer,
    'weak_node,
    'dead_node,
    'scope_context,
    'stream_metrics )
  t

val core : (_, _, _, _, _, _, _, _, _, _, _) t -> Eta_signal_graph_core.t

val stabilization :
  ( 'pending,
    'bind,
    'node,
    'hook,
    'timer,
    'refresh,
    'observer,
    'weak_node,
    'dead_node,
    'scope_context,
    'stream_metrics )
  t ->
  ( ( 'pending,
      'bind,
      'node,
      'hook,
      'timer,
      'refresh,
      'observer,
      'weak_node,
      'dead_node,
      'scope_context,
      'stream_metrics )
    t,
    Eta_signal_error.graph_error )
  Eta_signal_stabilization.t

val state :
  ( 'pending,
    'bind,
    'node,
    'hook,
    'timer,
    'refresh,
    _,
    _,
    _,
    _,
    _ )
  t ->
  ('pending, 'bind, 'node, 'hook, 'timer, 'refresh) Eta_signal_graph_state.t

val current_scope :
  (_, _, _, _, _, _, _, _, _, 'scope_context, _) t -> 'scope_context

val stream_bridge_metrics :
  (_, _, _, _, _, _, _, _, _, _, 'stream_metrics) t -> 'stream_metrics

val set_stream_bridge_metrics :
  (_, _, _, _, _, _, _, _, _, _, 'stream_metrics) t -> 'stream_metrics -> unit

val observers :
  (_, _, _, _, _, _, 'observer, _, _, _, _) t -> 'observer list

val add_observer :
  (_, _, _, _, _, _, 'observer, _, _, _, _) t -> 'observer -> unit

val update_observers :
  (_, _, _, _, _, _, 'observer, _, _, _, _) t ->
  ('observer list -> 'observer list) ->
  unit

val observer_delivery_plan :
  (_, _, _, _, _, _, 'observer, _, _, _, _) t ->
  active:('observer -> bool) ->
  compare:('observer -> 'observer -> int) ->
  collect_event:('capability -> 'observer -> 'event option) ->
  mark_pending:('capability -> 'event -> unit) ->
  ('capability, 'observer, 'event) Eta_signal_stabilization_pass.observer_plan
(** Capture active observers and defer graph-ordered delivery event planning
    until the stabilization pass reaches the event collection phase. *)

val collect_nodes :
  (_, _, _, _, _, _, _, 'weak_node, _, _, _) t ->
  ('weak_node list -> 'weak_node list * 'node list) ->
  'node list

val remember_node :
  (_, _, _, _, _, _, _, 'weak_node, _, _, _) t -> 'weak_node -> unit

val prune_nodes :
  (_, _, _, _, _, _, _, 'weak_node, _, _, _) t ->
  ('weak_node list -> 'weak_node list * 'node list) ->
  unit

val dead_nodes : (_, _, _, _, _, _, _, _, 'dead_node, _, _) t -> 'dead_node list

val dead_node_count : (_, _, _, _, _, _, _, _, _, _, _) t -> int

val remember_dead_node :
  (_, _, _, _, _, _, _, _, 'dead_node, _, _) t ->
  max_count:int ->
  id:('dead_node -> 'id) ->
  equal_id:('id -> 'id -> bool) ->
  'dead_node ->
  unit
