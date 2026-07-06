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

type lane_access

type lane_hooks

val lane_hooks :
  note_waiter_enqueued:(unit -> unit) ->
  note_waiter_compaction:(unit -> unit) ->
  lane_hooks

type counter =
  | Callback_delivery_count
  | Recompute_count
  | Dynamic_scope_invalidations
  | Nodes_became_necessary
  | Nodes_became_unnecessary

type staging

type ('id, 'node) node_identity

val node_identity :
  id:('node -> 'id) ->
  equal_id:('id -> 'id -> bool) ->
  ('id, 'node) node_identity

type ('id, 'node) edge_ops

val edge_ops :
  identity:('id, 'node) node_identity ->
  dependencies:('node -> 'node list) ->
  set_dependencies:('node -> 'node list -> unit) ->
  dependents:('node -> 'node list) ->
  set_dependents:('node -> 'node list -> unit) ->
  ('id, 'node) edge_ops

type ('id, 'node) dirty_ops

val dirty_ops :
  identity:('id, 'node) node_identity ->
  dirty:('node -> bool) ->
  set_dirty:('node -> bool -> unit) ->
  ('id, 'node) dirty_ops

type ('node, 'compute_node) compute_ops

val compute_ops :
  node:('node -> 'compute_node) ->
  pack:('compute_node -> 'node) ->
  seen_generation:('compute_node -> int) ->
  set_seen_generation:('compute_node -> int -> unit) ->
  changed_seen:('compute_node -> bool) ->
  set_changed_seen:('compute_node -> bool -> unit) ->
  computing:('compute_node -> bool) ->
  set_computing:('compute_node -> bool -> unit) ->
  computed_generation:('compute_node -> int) ->
  set_computed_generation:('compute_node -> int -> unit) ->
  ('node, 'compute_node) compute_ops

type ('id, 'node) version_ops

val version_ops :
  identity:('id, 'node) node_identity ->
  version:('node -> int) ->
  ('id, 'node) version_ops

type ('id, 'node) order_ops

val order_ops :
  identity:('id, 'node) node_identity ->
  compare_id:('id -> 'id -> int) ->
  children:('node -> 'node list) ->
  ('id, 'node) order_ops

type ('id, 'node) reachable_ops

val reachable_ops :
  id:('node -> 'id) ->
  valid:('node -> bool) ->
  children:('node -> 'node list) ->
  ('id, 'node) reachable_ops

type ('scope_context, 'scope) scope_ops

val scope_ops :
  current:('scope_context -> 'scope option) ->
  require_valid_current:
    ('scope_context -> ('scope, [ `Ambiguous_scope ]) result) ->
  with_current:('a. 'scope_context -> 'scope -> (unit -> 'a) -> 'a) ->
  ('scope_context, 'scope) scope_ops

type ('scope, 'dependency, 'node, 'packed_node, 'weak_node) node_lifecycle

val node_lifecycle :
  validate_dependency:('dependency -> unit) ->
  create:(id:Eta_signal_id.signal -> scope:'scope option -> 'node) ->
  attach_dependency:(parent:'node -> child:'dependency -> unit) ->
  add_to_scope:('scope -> 'node -> unit) ->
  pack:('node -> 'packed_node) ->
  create_weak:('packed_node -> 'weak_node) ->
  ('scope, 'dependency, 'node, 'packed_node, 'weak_node) node_lifecycle

type ('node, 'scope, 'hook, 'dead_node) node_invalidation

val node_invalidation :
  valid:('node -> bool) ->
  set_invalid:('node -> unit) ->
  timer_hooks:('node -> 'hook list) ->
  tombstone:('node -> 'dead_node) ->
  tombstone_id:('dead_node -> Eta_signal_id.signal) ->
  observer_hooks:('node -> 'hook list) ->
  kind_hooks:
    (invalidate_scope:(?prune:bool -> 'scope -> 'hook list) ->
    'node ->
    'hook list) ->
  ('node, 'scope, 'hook, 'dead_node) node_invalidation

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

val context_error_message : string

val ensure_context : (_, _, _, _, _, _, _, _, _, _, _) t -> unit

val with_lane_access :
  (_, _, _, _, _, _, _, _, _, _, _) t ->
  leaf_name:string ->
  depth_local:int Eta.Runtime_contract.local ->
  hooks:lane_hooks ->
  after_acquired:(unit -> (unit, 'error) Eta.Effect.t) ->
  (lane_access -> 'a) ->
  ('a, 'error) Eta.Effect.t

val lane_waiting_count :
  (_, _, _, _, _, _, _, _, _, _, _) t -> lane_access -> int

val lane_cancelled_count :
  (_, _, _, _, _, _, _, _, _, _, _) t -> lane_access -> int

val next_var_id :
  (_, _, _, _, _, _, _, _, _, _, _) t ->
  (Eta_signal_id.var, Eta_signal_error.graph_error) result

val next_observer_id :
  (_, _, _, _, _, _, _, _, _, _, _) t ->
  (Eta_signal_id.observer, Eta_signal_error.graph_error) result

val next_scope_id :
  (_, _, _, _, _, _, _, _, _, _, _) t ->
  (Eta_signal_id.scope, Eta_signal_error.graph_error) result

val set_next_node_id :
  (_, _, _, _, _, _, _, _, _, _, _) t -> lane_access -> int -> unit

val counter :
  (_, _, _, _, _, _, _, _, _, _, _) t -> lane_access -> counter -> int

val set_counter :
  (_, _, _, _, _, _, _, _, _, _, _) t -> lane_access -> counter -> int -> unit

val bump_counter :
  (_, _, _, _, _, _, _, _, _, _, _) t -> lane_access -> counter -> unit

val detach_dependency :
  (_, _, _, _, _, _, _, _, _, _, _) t ->
  lane_access ->
  ('id, 'node) edge_ops ->
  parent:'node ->
  child:'node ->
  unit

val attach_dependency :
  (_, _, _, _, _, _, _, _, _, _, _) t ->
  lane_access ->
  ('id, 'node) edge_ops ->
  parent:'node ->
  child:'node ->
  unit

val mark_dirty :
  (_, _, _, _, _, _, _, _, _, _, _) t ->
  lane_access ->
  ('id, 'node) dirty_ops ->
  'node ->
  unit

val mark_dirty_recording_previous :
  (_, _, _, _, _, _, _, _, _, _, _) t ->
  lane_access ->
  ('id, 'node) dirty_ops ->
  ('node * bool) list ->
  'node ->
  ('node * bool) list

val restore_dirty :
  (_, _, _, _, _, _, _, _, _, _, _) t ->
  lane_access ->
  ('id, 'node) dirty_ops ->
  ('node * bool) list ->
  unit

val generation : (_, _, _, _, _, _, _, _, _, _, _) t -> lane_access -> int

val set_generation :
  (_, _, _, _, _, _, _, _, _, _, _) t -> lane_access -> int -> unit

val enqueue_pending :
  ('pending, _, _, _, _, _, _, _, _, _, _) t ->
  lane_access ->
  'pending ->
  unit

val remember_computed :
  (_, _, 'node, _, _, _, _, _, _, _, _) t ->
  lane_access ->
  staging ->
  ('node, 'compute_node) compute_ops ->
  'node ->
  unit

val iter_computed :
  (_, _, 'node, _, _, _, _, _, _, _, _) t ->
  lane_access ->
  staging ->
  f:('node -> unit) ->
  unit

val compute_cached :
  (_, _, _, _, _, _, _, _, _, _, _) t ->
  lane_access ->
  ('node, 'compute_node) compute_ops ->
  'node ->
  current:('compute_node -> 'a) ->
  cycle:('compute_node -> 'a * bool) ->
  compute:('compute_node -> 'a * bool) ->
  'a * bool

val version_snapshot :
  (_, _, _, _, _, _, _, _, _, _, _) t ->
  lane_access ->
  ('id, 'node) version_ops ->
  'node list ->
  ('id * int) list

val versions_changed :
  (_, _, _, _, _, _, _, _, _, _, _) t ->
  lane_access ->
  ('id, 'node) version_ops ->
  current:('id * int) list ->
  'node list ->
  bool

val compare_order :
  (_, _, _, _, _, _, _, _, _, _, _) t ->
  lane_access ->
  ('id, 'node) order_ops ->
  'node ->
  'node ->
  int

type ('node, 'bind_node) bind_node_selection

val bind_node_selection :
  bind:('node -> 'bind_node option) -> ('node, 'bind_node) bind_node_selection

val collect_reachable_bind_nodes :
  (_, _, _, _, _, _, _, _, _, _, _) t ->
  lane_access ->
  ('id, 'node) reachable_ops ->
  roots:'node list ->
  ('node, 'bind_node) bind_node_selection ->
  'bind_node list
(** Traverse valid reachable nodes from [roots], deduplicate by node id, and
    return bind nodes selected by the caller's concrete node representation. *)

val stage_bind_switch :
  (_, 'bind, _, _, _, _, _, _, _, _, _) t ->
  lane_access ->
  staging ->
  'bind ->
  ('source, 'inner, 'scope) Eta_signal_bind.snapshot
  Eta_signal_transaction.staged ->
  source_value:'source ->
  inner:'inner ->
  scope:'scope ->
  unit

val commit_staged_bind_switch :
  ('source, 'inner, 'scope, 'owner) Eta_signal_bind.staged_switch ->
  ('owner, 'inner, 'scope, 'hook) Eta_signal_bind.staged_switch_lifecycle ->
  ('hook list, Eta_signal_error.graph_error) result

val rollback_staged_bind_switch :
  staged:
    ('source, 'inner, 'scope) Eta_signal_bind.snapshot option ->
  ('owner, 'inner, 'scope, 'hook) Eta_signal_bind.staged_switch_lifecycle ->
  ('hook list, Eta_signal_error.graph_error) result

val collect_staged_bind_switch_invalidations :
  (_, 'bind, _, _, _, _, _, _, _, _, _) t ->
  lane_access ->
  staging ->
  init:'acc ->
  staged_switch:
    ('bind -> ('scope, 'owner) Eta_signal_bind.packed_staged_switch) ->
  collect_old_scope:('acc -> owner:'owner -> 'scope -> 'acc) ->
  ('acc, Eta_signal_error.graph_error) result

val remember_pure_disposal_hooks :
  (_, _, _, 'hook, _, _, _, _, _, _, _) t ->
  lane_access ->
  staging ->
  'hook list ->
  unit

val remember_timer_refresh_disposal_hooks :
  (_, _, _, 'hook, _, _, _, _, _, _, _) t ->
  lane_access ->
  staging ->
  'hook list ->
  unit

type ('bind, 'hook, 'timer, 'refresh) staging_reset_context

val staging_reset_context :
  rollback_bind:(staging -> 'bind -> 'hook list) ->
  rollback_timer_refresh_dirty:('refresh -> unit) ->
  clear_timer_refresh_timer:('timer -> unit) ->
  ('bind, 'hook, 'timer, 'refresh) staging_reset_context

val reset_staging :
  ('pending, 'bind, 'node, 'hook, 'timer, 'refresh, _, _, _, _, _) t ->
  lane_access ->
  staging ->
  ('bind, 'hook, 'timer, 'refresh) staging_reset_context ->
  'hook list

type ('bind, 'hook) staging_bind_commit_plan

val staging_bind_commit_plan :
  commit:(staging -> 'bind -> 'hook list) ->
  ('bind, 'hook) staging_bind_commit_plan

type 'node staging_signal_commit_plan

val staging_signal_commit_plan :
  prepare_signal:(staging -> 'node -> unit) ->
  commit_signal:('node -> unit) ->
  'node staging_signal_commit_plan

type 'timer staging_timer_commit_plan

val staging_timer_commit_plan :
  commit:('timer -> unit) ->
  'timer staging_timer_commit_plan

type ('bind, 'node, 'hook, 'timer) staging_commit_plan

val staging_commit_plan :
  preflight:(staging -> unit) ->
  binds:('bind, 'hook) staging_bind_commit_plan ->
  signals:'node staging_signal_commit_plan ->
  timers:'timer staging_timer_commit_plan ->
  ('bind, 'node, 'hook, 'timer) staging_commit_plan

val commit_staging :
  ('pending, 'bind, 'node, 'hook, 'timer, 'refresh, _, _, _, _, _) t ->
  lane_access ->
  staging ->
  ('bind, 'node, 'hook, 'timer) staging_commit_plan ->
  ('hook list, Eta_signal_error.graph_error) result

val pure_snapshot_commit_count :
  (_, _, _, _, _, _, _, _, _, _, _) t -> lane_access -> int

val set_pure_snapshot_commit_count :
  (_, _, _, _, _, _, _, _, _, _, _) t -> lane_access -> int -> unit

val read_effective :
  (_, _, _, _, _, _, _, _, _, _, _) t ->
  'a Eta_signal_transaction.staged ->
  'a

val stage_cell :
  (_, _, _, _, _, _, _, _, _, _, _) t ->
  lane_access ->
  staging ->
  'a Eta_signal_transaction.staged ->
  'a ->
  unit

val update_cell :
  (_, _, _, _, _, _, _, _, _, _, _) t ->
  lane_access ->
  staging ->
  'a Eta_signal_transaction.staged ->
  ('a -> 'a) ->
  unit

val staged_in_active_transaction :
  (_, _, _, _, _, _, _, _, _, _, _) t ->
  lane_access ->
  staging ->
  'a Eta_signal_transaction.staged ->
  bool

val staged_value :
  (_, _, _, _, _, _, _, _, _, _, _) t ->
  lane_access ->
  staging ->
  'a Eta_signal_transaction.staged ->
  'a option

val discard_staging :
  (_, _, _, _, _, _, _, _, _, _, _) t ->
  lane_access ->
  staging ->
  'a Eta_signal_transaction.staged ->
  unit

val next_timer_refresh_token :
  (_, _, _, _, _, _, _, _, _, _, _) t ->
  lane_access ->
  (int, Eta_signal_error.graph_error) result

val set_next_timer_refresh_token :
  (_, _, _, _, _, _, _, _, _, _, _) t -> lane_access -> int -> unit

val mark_timer_refresh_dirty :
  (_, _, _, _, _, 'refresh, _, _, _, _, _) t ->
  lane_access ->
  staging ->
  mark:(unit -> unit) ->
  record:('refresh -> unit) ->
  unit

val timer_has_staged_refresh :
  (_, _, _, _, _, 'refresh, _, _, _, _, _) t ->
  'timer ->
  refresh_token:('refresh -> int) ->
  staged_token:('timer -> int) ->
  bool

val remember_timer_refresh_timer :
  (_, _, _, _, 'timer, 'refresh, _, _, _, _, _) t ->
  lane_access ->
  staging ->
  'timer ->
  refresh_token:('refresh -> int) ->
  staged_token:('timer -> int) ->
  set_staged_token:('timer -> int -> unit) ->
  stage_refresh_token:('timer -> int -> unit) ->
  unit

val with_timer_refresh_timer :
  (_, _, _, _, _, 'refresh, _, _, _, _, _) t ->
  lane_access ->
  'timer option ->
  none:(unit -> 'a) ->
  some:('refresh -> 'timer -> 'a) ->
  'a

val allocation_scope :
  (_, _, _, _, _, _, _, _, _, 'scope_context, _) t ->
  ('scope_context, 'scope) scope_ops ->
  ('scope option, Eta_signal_error.graph_error) result

val with_current_scope :
  (_, _, _, _, _, _, _, _, _, 'scope_context, _) t ->
  ('scope_context, 'scope) scope_ops ->
  'scope ->
  (unit -> 'a) ->
  'a

val ensure_not_pure :
  (_, _, _, _, _, _, _, _, _, _, _) t ->
  (unit, Eta_signal_error.graph_error) result

val stream_bridge_metrics :
  (_, _, _, _, _, _, _, _, _, _, 'stream_metrics) t -> 'stream_metrics

val set_stream_bridge_metrics :
  (_, _, _, _, _, _, _, _, _, _, 'stream_metrics) t ->
  lane_access ->
  'stream_metrics ->
  unit

val add_observer :
  (_, _, _, _, _, _, 'observer, _, _, _, _) t ->
  lane_access ->
  'observer ->
  unit

val remove_observer :
  (_, _, _, _, _, _, 'observer, _, _, _, _) t ->
  lane_access ->
  same:('observer -> 'observer -> bool) ->
  'observer ->
  unit

type ('observer, 'hook) observer_cleanup

val observer_cleanup :
  selected:('observer -> bool) ->
  cleanup:('observer -> 'hook list) ->
  ('observer, 'hook) observer_cleanup

val collect_observer_cleanup_hooks :
  (_, _, _, _, _, _, 'observer, _, _, _, _) t ->
  lane_access ->
  ('observer, 'hook) observer_cleanup ->
  'hook list
(** Observer cleanup for node invalidation. The graph owns registry traversal;
    callers supply lifecycle predicates and cleanup-hook construction for their
    concrete observer representation. *)

type observer_counts

val observer_counts :
  (_, _, _, _, _, _, 'observer, _, _, _, _) t ->
  lane_access ->
  active:('observer -> bool) ->
  invalid:('observer -> bool) ->
  observer_counts

val observer_counts_active : observer_counts -> int
val observer_counts_invalid : observer_counts -> int

type ('observer, 'diagnostic) observer_diagnostics

val observer_diagnostics :
  visible:('observer -> bool) ->
  diagnostic:('observer -> 'diagnostic) ->
  ('observer, 'diagnostic) observer_diagnostics

val collect_observer_diagnostics :
  (_, _, _, _, _, _, 'observer, _, _, _, _) t ->
  lane_access ->
  ('observer, 'diagnostic) observer_diagnostics ->
  'diagnostic list
(** Observer registry diagnostics. The graph owns registry traversal; callers
    supply lifecycle predicates and diagnostic projections for their concrete
    observer representation. *)

val observer_delivery_plan :
  (_, _, _, _, _, _, 'observer, _, _, _, _) t ->
  lane_access ->
  (lane_access, 'observer, 'event) Eta_signal_observer.delivery_collection ->
  (lane_access, 'observer, 'event) Eta_signal_stabilization_pass.observer_plan
(** Capture active observers and defer graph-ordered delivery event collection
    until the stabilization pass reaches the event collection phase. The graph
    owns registry traversal; the observer subsystem owns active filtering,
    delivery ordering, event collection, and pending-state marking. *)

type 'pending stabilization_pending_plan

val stabilization_pending_plan :
  release_marks:(lane_access -> 'pending list -> unit) ->
  stage:(lane_access -> staging -> 'pending list -> unit) ->
  'pending stabilization_pending_plan

type ('observer, 'event) stabilization_observer_plan

val stabilization_observer_plan :
  observe:
    (lane_access ->
    staging ->
    (lane_access, 'observer, 'event)
    Eta_signal_stabilization_pass.observer_plan) ->
  plan_staged_binds:(lane_access -> staging -> 'observer list -> unit) ->
  ('observer, 'event) stabilization_observer_plan

type 'hook stabilization_commit_plan

val stabilization_commit_plan :
  commit_staging:(lane_access -> staging -> 'hook list) ->
  update_necessity:(lane_access -> unit) ->
  'hook stabilization_commit_plan

type ('pending, 'observer, 'event, 'hook) stabilization_pure

val stabilization_pure_ops :
  pending:'pending stabilization_pending_plan ->
  observers:('observer, 'event) stabilization_observer_plan ->
  commit:'hook stabilization_commit_plan ->
  ('pending, 'observer, 'event, 'hook) stabilization_pure

type ('pending, 'observer, 'hook) stabilization_rollback

val stabilization_rollback_ops :
  rollback_staging:(lane_access -> staging -> 'hook list) ->
  mark_observers_failed_without_current:(lane_access -> 'observer list -> unit) ->
  requeue_pending:(lane_access -> 'pending list -> unit) ->
  ('pending, 'observer, 'hook) stabilization_rollback

type ('pending, 'observer, 'event, 'hook) stabilization_ops

val stabilization_ops :
  classify_graph_error:(exn -> Eta_signal_error.graph_error option) ->
  pure:
    ('pending, 'observer, 'event, 'hook) stabilization_pure ->
  rollback:('pending, 'observer, 'hook) stabilization_rollback ->
  ('pending, 'observer, 'event, 'hook) stabilization_ops

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
  lane_access ->
  timer_refresh:'refresh option ->
  ( 'pending,
    'observer,
    'event,
    'hook )
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
    timer-refresh cleanup. This module owns graph generation advancement,
    staging setup, pending draining, the stabilization object, and the
    graph-state finalizer; callers provide the remaining graph-specific
    pure/rollback plans. *)

type 'owner stabilization_finish

val create_stabilization_finish : unit -> 'owner stabilization_finish

val record_stabilization_result :
  'owner stabilization_finish ->
  lane_access ->
  ('owner, 'hook, 'event, Eta_signal_error.graph_error)
  Eta_signal_stabilization_pass.result ->
  'hook list
(** Remember the delivering token from a pure pass result and return the
    cleanup hooks carried by that result. The lane capability makes
    delivering-token bookkeeping part of graph mutation, so callers do not
    need to inspect successful stabilization results just to finish the graph
    phase later. *)

val stabilization_finish_pending : 'owner stabilization_finish -> bool

val finish_recorded_stabilization :
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
  lane_access ->
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
    t )
  stabilization_finish ->
  unit

type ('event, 'error) stabilization_delivery_context

val stabilization_delivery_context :
  run_pending_cleanup:(unit -> (unit, 'error) Eta.Effect.t) ->
  run_events:('event list -> (unit, 'error) Eta.Effect.t) ->
  with_lane_access:((lane_access -> unit) -> (unit, 'error) Eta.Effect.t) ->
  ('event, 'error) stabilization_delivery_context

val stabilization_delivery_ops :
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
    t )
  stabilization_finish ->
  ('event, 'error) stabilization_delivery_context ->
  ('event, 'error) Eta_signal_stabilization_pass.delivery
(** Build the delivering-phase plan for a recorded graph stabilization. The
    caller supplies effectful cleanup, observer event execution, and graph-lane
    acquisition; the graph owns the callback-delivery counter and finishing the
    recorded stabilization token. *)

val create_live_node :
  (_, _, _, _, _, _, _, 'weak_node, _, 'scope_context, _) t ->
  ('scope_context, 'scope) scope_ops ->
  ('scope, 'dependency, 'node, 'packed_node, 'weak_node) node_lifecycle ->
  dependencies:'dependency list ->
  ('node, Eta_signal_error.graph_error) result

val invalidate_live_node :
  (_, _, _, _, _, _, _, _, 'dead_node, _, _) t ->
  lane_access ->
  ('id, 'node) edge_ops ->
  ('node, 'scope, 'hook, 'dead_node) node_invalidation ->
  invalidate_scope:(?prune:bool -> 'scope -> 'hook list) ->
  'node ->
  'hook list
(** Invalidate one live node and any currently attached dependents. The graph
    owns the lifecycle order: timer cleanup planning, validity flip,
    tombstone recording, observer cleanup planning, edge detachment, dependent
    invalidation, then kind-specific cleanup. *)

type ('node, 'weak_node) live_node_registry

val live_node_registry :
  collect_live_nodes:
    (('node -> bool) -> 'weak_node list -> 'weak_node list * 'node list) ->
  ('node, 'weak_node) live_node_registry

val live_nodes :
  (_, _, _, _, _, _, _, 'weak_node, _, _, _) t ->
  lane_access ->
  ('node, 'weak_node) live_node_registry ->
  'node list

val prune_live_nodes :
  (_, _, _, _, _, _, _, 'weak_node, _, _, _) t ->
  lane_access ->
  ('node, 'weak_node) live_node_registry ->
  keep:('node -> bool) ->
  unit

type necessary_snapshot

val necessary_count : necessary_snapshot -> int
val necessary_mem : necessary_snapshot -> Eta_signal_id.signal -> bool

type ('observer, 'node) demand_roots

val demand_roots :
  demand:('observer -> bool) ->
  root:('observer -> 'node) ->
  ('observer, 'node) demand_roots
(** Describe which observers demand graph roots. The graph owns observer
    registry traversal; callers supply lifecycle demand and concrete root
    projection for their observer representation. *)

type ('observer, 'node, 'weak_node) reachable_plan

val reachable_plan :
  ops:(Eta_signal_id.signal, 'node) reachable_ops ->
  registry:('node, 'weak_node) live_node_registry ->
  roots:('observer, 'node) demand_roots ->
  ('observer, 'node, 'weak_node) reachable_plan
(** Package graph-shape reachability with live-node pruning and observer root
    projection so demand snapshots use one assembled traversal plan. *)

val necessary_ids :
  (_, _, 'node, _, _, _, 'observer, 'weak_node, _, _, _) t ->
  lane_access ->
  ('observer, 'node, 'weak_node) reachable_plan ->
  necessary_snapshot
(** Recompute the current necessary node set from graph-owned observer and
    weak-node registries. The graph owns registry traversal and pruning; the
    caller supplies graph-shape projection and reachability. *)

val update_necessity :
  (_, _, 'node, _, _, _, 'observer, 'weak_node, _, _, _) t ->
  lane_access ->
  ('observer, 'node, 'weak_node) reachable_plan ->
  necessary_snapshot
(** Recompute necessary nodes and update graph-core transition counters from
    the same snapshot. *)

type 'timer timer_demand

type ('observer, 'node, 'weak_node, 'timer) timer_demand_source

val timer_demand_source :
  reachable:('observer, 'node, 'weak_node) reachable_plan ->
  timer:('node -> (Eta_signal_id.signal * 'timer) option) ->
  ('observer, 'node, 'weak_node, 'timer) timer_demand_source
(** Package graph reachability with timer extraction so timer-demand snapshots
    and post-commit preflight use one assembled graph-demand source. *)

val timer_demand :
  (_, _, 'node, _, _, _, 'observer, 'weak_node, _, _, _) t ->
  lane_access ->
  ('observer, 'node, 'weak_node, 'timer) timer_demand_source ->
  'timer timer_demand
(** Snapshot graph demand inputs for the timer subsystem. The graph owns the
    live-node registry traversal and observer-root necessary set; callers pass
    an assembled demand source rather than per-call projection callbacks. *)

val timer_demand_plan :
  'timer timer_demand ->
  plan:
    (is_necessary:(Eta_signal_id.signal -> bool) ->
    timers:(Eta_signal_id.signal * 'timer) list ->
    'plan) ->
  'plan
(** Convert a graph-owned timer-demand snapshot into a caller-owned timer
    plan without exposing the snapshot representation. *)

val post_commit_necessary_timers :
  (_, _, 'node, _, _, _, 'observer, 'weak_node, _, _, _) t ->
  lane_access ->
  ('observer, 'node, 'weak_node, 'timer) timer_demand_source ->
  (Eta_signal_id.signal, 'timer) Hashtbl.t
(** Collect the timers that will remain necessary after committing graph
    staging. The graph owns live-node pruning and observer-root traversal;
    callers supply one demand source because staged bind invalidation is
    graph-shape specific. *)

val dead_node_count :
  (_, _, _, _, _, _, _, _, _, _, _) t -> lane_access -> int

val iter_dead_nodes :
  (_, _, _, _, _, _, _, _, 'dead_node, _, _) t ->
  lane_access ->
  f:('dead_node -> unit) ->
  unit

val map_dead_nodes :
  (_, _, _, _, _, _, _, _, 'dead_node, _, _) t ->
  lane_access ->
  f:('dead_node -> 'a) ->
  'a list

val remember_dead_node :
  (_, _, _, _, _, _, _, _, 'dead_node, _, _) t ->
  lane_access ->
  id:('dead_node -> Eta_signal_id.signal) ->
  'dead_node ->
  unit
