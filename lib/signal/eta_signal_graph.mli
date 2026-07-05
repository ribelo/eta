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

val add_observer :
  (_, _, _, _, _, _, 'observer, _, _, _, _) t -> 'observer -> unit

val remove_observers :
  (_, _, _, _, _, _, 'observer, _, _, _, _) t ->
  keep:('observer -> bool) ->
  unit

val matching_observers :
  (_, _, _, _, _, _, 'observer, _, _, _, _) t ->
  selected:('observer -> bool) ->
  'observer list

val count_observers :
  (_, _, _, _, _, _, 'observer, _, _, _, _) t ->
  selected:('observer -> bool) ->
  int

val filter_map_observers :
  (_, _, _, _, _, _, 'observer, _, _, _, _) t ->
  f:('observer -> 'a option) ->
  'a list
(** Observer registry operations. The graph owns list traversal and mutation;
    callers supply lifecycle predicates and projections for their concrete
    observer representation. *)

val observer_delivery_plan :
  (_, _, _, _, _, _, 'observer, _, _, _, _) t ->
  active:('observer -> bool) ->
  compare:('observer -> 'observer -> int) ->
  collect_event:('capability -> 'observer -> 'event option) ->
  mark_pending:('capability -> 'event -> unit) ->
  ('capability, 'observer, 'event) Eta_signal_stabilization_pass.observer_plan
(** Capture active observers and defer graph-ordered delivery event planning
    until the stabilization pass reaches the event collection phase. *)

type ('capability, 'pending, 'observer, 'event, 'hook, 'staging)
     stabilization_ops =
  {
    errors : Eta_signal_error.graph_error Eta_signal_stabilization_pass.errors;
    pure :
      ( 'capability,
        'pending,
        'observer,
        'event,
        'hook,
        'staging )
      Eta_signal_stabilization_pass.pure;
    rollback :
      ('capability, 'pending, 'observer, 'hook, 'staging)
      Eta_signal_stabilization_pass.rollback;
  }

val run_stabilization :
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
  'capability ->
  ( 'capability,
    'pending,
    'observer,
    'event,
    'hook,
    'staging )
  stabilization_ops ->
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
    'hook,
    'event,
    Eta_signal_error.graph_error )
  Eta_signal_stabilization_pass.result
(** Run the graph stabilization pass with graph-owned phase state and
    timer-refresh cleanup. Callers provide graph-specific pure/rollback plans;
    this module owns the stabilization object and graph-state finalizer. *)

val finish_stabilization :
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
    Eta_signal_stabilization.delivering )
  Eta_signal_stabilization.token ->
  unit

val remember_node :
  (_, _, _, _, _, _, _, 'weak_node, _, _, _) t -> 'weak_node -> unit

val live_nodes :
  (_, _, _, _, _, _, _, 'weak_node, _, _, _) t ->
  collect_live_nodes:
    (('node -> bool) -> 'weak_node list -> 'weak_node list * 'node list) ->
  'node list

val prune_live_nodes :
  (_, _, _, _, _, _, _, 'weak_node, _, _, _) t ->
  collect_live_nodes:
    (('node -> bool) -> 'weak_node list -> 'weak_node list * 'node list) ->
  keep:('node -> bool) ->
  unit

val necessary_ids :
  (_, _, 'node, _, _, _, 'observer, 'weak_node, _, _, _) t ->
  collect_live_nodes:
    (('node -> bool) -> 'weak_node list -> 'weak_node list * 'node list) ->
  root:('observer -> 'node option) ->
  reachable_ids:
    (roots:'node list -> (Eta_signal_id.signal, unit) Hashtbl.t) ->
  (Eta_signal_id.signal, unit) Hashtbl.t
(** Recompute the current necessary node set from graph-owned observer and
    weak-node registries. The graph owns registry traversal and pruning; the
    caller supplies graph-shape projection and reachability. *)

val update_necessity :
  (_, _, 'node, _, _, _, 'observer, 'weak_node, _, _, _) t ->
  Eta_signal_graph_core.lane_access ->
  collect_live_nodes:
    (('node -> bool) -> 'weak_node list -> 'weak_node list * 'node list) ->
  root:('observer -> 'node option) ->
  reachable_ids:
    (roots:'node list -> (Eta_signal_id.signal, unit) Hashtbl.t) ->
  (Eta_signal_id.signal, unit) Hashtbl.t
(** Recompute necessary nodes and update graph-core transition counters from
    the same snapshot. *)

type ('id, 'timer) timer_demand = {
  timer_demand_necessary_ids : (Eta_signal_id.signal, unit) Hashtbl.t;
  timer_demand_timers : ('id * 'timer) list;
}

val timer_demand :
  (_, _, 'node, _, _, _, 'observer, 'weak_node, _, _, _) t ->
  collect_live_nodes:
    (('node -> bool) -> 'weak_node list -> 'weak_node list * 'node list) ->
  root:('observer -> 'node option) ->
  reachable_ids:
    (roots:'node list -> (Eta_signal_id.signal, unit) Hashtbl.t) ->
  timer:('node -> ('id * 'timer) option) ->
  ('id, 'timer) timer_demand
(** Snapshot graph demand inputs for the timer subsystem. The graph owns the
    live-node registry traversal and observer-root necessary set; the caller
    supplies graph-shape projections for reachability and timer extraction. *)

val post_commit_necessary_timers :
  (_, _, 'node, _, _, _, 'observer, 'weak_node, _, _, _) t ->
  collect_live_nodes:
    (('node -> bool) -> 'weak_node list -> 'weak_node list * 'node list) ->
  root:('observer -> 'node option) ->
  collect_timers:(roots:'node list -> ('id, 'timer) Hashtbl.t) ->
  ('id, 'timer) Hashtbl.t
(** Collect the timers that will remain necessary after committing graph
    staging. The graph owns live-node pruning and observer-root traversal;
    callers supply the post-commit reachability rules because staged bind
    invalidation is graph-shape specific. *)

val dead_node_count : (_, _, _, _, _, _, _, _, _, _, _) t -> int

val iter_dead_nodes :
  (_, _, _, _, _, _, _, _, 'dead_node, _, _) t ->
  f:('dead_node -> unit) ->
  unit

val map_dead_nodes :
  (_, _, _, _, _, _, _, _, 'dead_node, _, _) t ->
  f:('dead_node -> 'a) ->
  'a list

val remember_dead_node :
  (_, _, _, _, _, _, _, _, 'dead_node, _, _) t ->
  max_count:int ->
  id:('dead_node -> 'id) ->
  equal_id:('id -> 'id -> bool) ->
  'dead_node ->
  unit
