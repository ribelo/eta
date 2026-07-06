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
  t =
  {
    core : Eta_signal_graph_core.t;
    stabilization :
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
      Eta_signal_stabilization.t;
    state :
      ('pending, 'bind, 'node, 'hook, 'timer, 'refresh)
      Eta_signal_graph_state.t;
    mutable observers : 'observer list;
    mutable all_nodes : 'weak_node list;
    mutable dead_nodes : 'dead_node list;
    current_scope : 'scope_context;
    mutable stream_bridge_metrics : 'stream_metrics;
  }

type lane_access = Eta_signal_graph_core.lane_access

type lane_hooks = {
  note_waiter_enqueued : unit -> unit;
  note_waiter_compaction : unit -> unit;
}

let lane_hooks ~note_waiter_enqueued ~note_waiter_compaction =
  { note_waiter_enqueued; note_waiter_compaction }

type counter =
  | Callback_delivery_count
  | Recompute_count
  | Dynamic_scope_invalidations
  | Nodes_became_necessary
  | Nodes_became_unnecessary

type staging = Eta_signal_graph_state.staging

type ('id, 'node) node_identity = {
  identity_id : 'node -> 'id;
  identity_equal_id : 'id -> 'id -> bool;
}

let node_identity ~id ~equal_id =
  { identity_id = id; identity_equal_id = equal_id }

type ('id, 'node) edge_ops = {
  edge_identity : ('id, 'node) node_identity;
  edge_dependencies : 'node -> 'node list;
  edge_set_dependencies : 'node -> 'node list -> unit;
  edge_dependents : 'node -> 'node list;
  edge_set_dependents : 'node -> 'node list -> unit;
}

type ('id, 'node) dirty_ops = {
  dirty_identity : ('id, 'node) node_identity;
  dirty : 'node -> bool;
  dirty_set : 'node -> bool -> unit;
}

type ('node, 'compute_node) compute_ops = {
  compute_node : 'node -> 'compute_node;
  compute_pack : 'compute_node -> 'node;
  compute_seen_generation : 'compute_node -> int;
  compute_set_seen_generation : 'compute_node -> int -> unit;
  compute_changed_seen : 'compute_node -> bool;
  compute_set_changed_seen : 'compute_node -> bool -> unit;
  compute_computing : 'compute_node -> bool;
  compute_set_computing : 'compute_node -> bool -> unit;
  compute_computed_generation : 'compute_node -> int;
  compute_set_computed_generation : 'compute_node -> int -> unit;
}

type ('id, 'node) version_ops = {
  version_identity : ('id, 'node) node_identity;
  version : 'node -> int;
}

type ('id, 'node) order_ops = {
  order_identity : ('id, 'node) node_identity;
  order_compare_id : 'id -> 'id -> int;
  order_children : 'node -> 'node list;
}

type ('id, 'node) reachable_ops = {
  reachable_id : 'node -> 'id;
  reachable_valid : 'node -> bool;
  reachable_children : 'node -> 'node list;
}

type ('scope_context, 'scope) scope_ops = {
  scope_current : 'scope_context -> 'scope option;
  scope_require_valid_current :
    'scope_context -> ('scope, [ `Ambiguous_scope ]) result;
  scope_with_current : 'a. 'scope_context -> 'scope -> (unit -> 'a) -> 'a;
}

let scope_ops (type scope_context scope)
    ~(current : scope_context -> scope option)
    ~(require_valid_current :
       scope_context -> (scope, [ `Ambiguous_scope ]) result)
    ~(with_current :
       'a. scope_context -> scope -> (unit -> 'a) -> 'a) =
  {
    scope_current = current;
    scope_require_valid_current = require_valid_current;
    scope_with_current = with_current;
  }

let edge_ops ~identity ~dependencies ~set_dependencies ~dependents
    ~set_dependents =
  {
    edge_identity = identity;
    edge_dependencies = dependencies;
    edge_set_dependencies = set_dependencies;
    edge_dependents = dependents;
    edge_set_dependents = set_dependents;
  }

let dirty_ops ~identity ~dirty ~set_dirty =
  {
    dirty_identity = identity;
    dirty;
    dirty_set = set_dirty;
  }

let compute_ops ~node ~pack ~seen_generation ~set_seen_generation
    ~changed_seen ~set_changed_seen ~computing ~set_computing
    ~computed_generation ~set_computed_generation =
  {
    compute_node = node;
    compute_pack = pack;
    compute_seen_generation = seen_generation;
    compute_set_seen_generation = set_seen_generation;
    compute_changed_seen = changed_seen;
    compute_set_changed_seen = set_changed_seen;
    compute_computing = computing;
    compute_set_computing = set_computing;
    compute_computed_generation = computed_generation;
    compute_set_computed_generation = set_computed_generation;
  }

let version_ops ~identity ~version = { version_identity = identity; version }

let order_ops ~identity ~compare_id ~children =
  {
    order_identity = identity;
    order_compare_id = compare_id;
    order_children = children;
  }

let reachable_ops ~id ~valid ~children =
  { reachable_id = id; reachable_valid = valid; reachable_children = children }

type ('scope, 'dependency, 'node, 'packed_node, 'weak_node) node_lifecycle =
  {
    node_validate_dependency : 'dependency -> unit;
    node_create : id:Eta_signal_id.signal -> scope:'scope option -> 'node;
    node_attach_dependency : parent:'node -> child:'dependency -> unit;
    node_add_to_scope : 'scope -> 'node -> unit;
    node_pack : 'node -> 'packed_node;
    node_create_weak : 'packed_node -> 'weak_node;
  }

type ('node, 'scope, 'hook, 'dead_node) node_invalidation = {
  invalidation_valid : 'node -> bool;
  invalidation_set_invalid : 'node -> unit;
  invalidation_timer_hooks : 'node -> 'hook list;
  invalidation_tombstone : 'node -> 'dead_node;
  invalidation_tombstone_id : 'dead_node -> Eta_signal_id.signal;
  invalidation_observer_hooks : 'node -> 'hook list;
  invalidation_kind_hooks :
    invalidate_scope:(?prune:bool -> 'scope -> 'hook list) ->
    'node ->
    'hook list;
}

let node_lifecycle ~validate_dependency ~create ~attach_dependency
    ~add_to_scope ~pack ~create_weak =
  {
    node_validate_dependency = validate_dependency;
    node_create = create;
    node_attach_dependency = attach_dependency;
    node_add_to_scope = add_to_scope;
    node_pack = pack;
    node_create_weak = create_weak;
  }

let node_invalidation ~valid ~set_invalid ~timer_hooks ~tombstone
    ~tombstone_id ~observer_hooks ~kind_hooks =
  {
    invalidation_valid = valid;
    invalidation_set_invalid = set_invalid;
    invalidation_timer_hooks = timer_hooks;
    invalidation_tombstone = tombstone;
    invalidation_tombstone_id = tombstone_id;
    invalidation_observer_hooks = observer_hooks;
    invalidation_kind_hooks = kind_hooks;
  }

let core_counter = function
  | Callback_delivery_count -> Eta_signal_graph_core.Callback_delivery_count
  | Recompute_count -> Eta_signal_graph_core.Recompute_count
  | Dynamic_scope_invalidations ->
      Eta_signal_graph_core.Dynamic_scope_invalidations
  | Nodes_became_necessary -> Eta_signal_graph_core.Nodes_became_necessary
  | Nodes_became_unnecessary -> Eta_signal_graph_core.Nodes_became_unnecessary

let create ~create_scope_context ~create_stream_bridge_metrics () =
  {
    core = Eta_signal_graph_core.create ();
    stabilization = Eta_signal_stabilization.create ();
    state = Eta_signal_graph_state.create ();
    observers = [];
    all_nodes = [];
    dead_nodes = [];
    current_scope = create_scope_context ();
    stream_bridge_metrics = create_stream_bridge_metrics ();
  }

let context_error_message = Eta_signal_graph_core.context_error_message
let ensure_context t = Eta_signal_graph_core.ensure_context t.core

let lane_hooks_to_core hooks =
  Eta_signal_graph_core.lane_hooks
    ~note_waiter_enqueued:hooks.note_waiter_enqueued
    ~note_waiter_compaction:hooks.note_waiter_compaction

let with_lane_access t ~leaf_name ~depth_local ~hooks ~after_acquired f =
  Eta_signal_graph_core.with_lane_access t.core ~leaf_name ~depth_local
    ~hooks:(lane_hooks_to_core hooks) ~after_acquired f

let lane_waiting_count t _lane =
  Eta_signal_graph_core.lane_waiting_count t.core

let lane_cancelled_count t _lane =
  Eta_signal_graph_core.lane_cancelled_count t.core
let next_signal_id t = Eta_signal_graph_core.next_signal_id t.core
let next_var_id t = Eta_signal_graph_core.next_var_id t.core
let next_observer_id t = Eta_signal_graph_core.next_observer_id t.core
let next_scope_id t = Eta_signal_graph_core.next_scope_id t.core
let set_next_node_id t _lane next =
  Eta_signal_graph_core.set_next_node_id t.core next

let counter t _lane target =
  Eta_signal_graph_core.counter t.core (core_counter target)

let set_counter t _lane target value =
  Eta_signal_graph_core.set_counter t.core (core_counter target) value

let bump_counter t lane target =
  Eta_signal_graph_core.bump_counter t.core lane (core_counter target)

let identity_id identity node = identity.identity_id node
let identity_equal identity left right = identity.identity_equal_id left right

let edge_id ops node = identity_id ops.edge_identity node
let edge_equal_id ops left right = identity_equal ops.edge_identity left right
let dirty_id ops node = identity_id ops.dirty_identity node
let dirty_equal_id ops left right =
  identity_equal ops.dirty_identity left right

let version_id ops node = identity_id ops.version_identity node
let version_equal_id ops left right =
  identity_equal ops.version_identity left right

let order_id ops node = identity_id ops.order_identity node
let order_equal_id ops left right =
  identity_equal ops.order_identity left right

let remove_by_id ops id node = not (edge_equal_id ops (edge_id ops node) id)

let has_id ops id node =
  edge_equal_id ops (edge_id ops node) id

let remove_dependent _t ops ~child ~parent =
  ops.edge_set_dependents child
    (List.filter
       (remove_by_id ops (edge_id ops parent))
       (ops.edge_dependents child))

let detach_dependency t _lane ops ~parent ~child =
  remove_dependent t ops ~child ~parent;
  ops.edge_set_dependencies parent
    (List.filter
       (remove_by_id ops (edge_id ops child))
       (ops.edge_dependencies parent))

let has_dependency _t ops ~parent ~child =
  List.exists
    (has_id ops (edge_id ops child))
    (ops.edge_dependencies parent)

let has_dependent _t ops ~child ~parent =
  List.exists
    (has_id ops (edge_id ops parent))
    (ops.edge_dependents child)

let attach_dependency t _lane ops ~parent ~child =
  if not (has_dependent t ops ~child ~parent) then
    ops.edge_set_dependents child (parent :: ops.edge_dependents child);
  if not (has_dependency t ops ~parent ~child) then
    ops.edge_set_dependencies parent (child :: ops.edge_dependencies parent)

let detach_node_edges t _lane ops node =
  let dependencies = ops.edge_dependencies node in
  let dependents = ops.edge_dependents node in
  List.iter
    (fun dependency -> remove_dependent t ops ~child:dependency ~parent:node)
    dependencies;
  ops.edge_set_dependencies node [];
  ops.edge_set_dependents node [];
  (dependencies, dependents)

let mark_dirty _t _lane ops node = ops.dirty_set node true

let same_dirty_node ops node (candidate, _) =
  dirty_equal_id ops (dirty_id ops node) (dirty_id ops candidate)

let mark_dirty_recording_previous t lane ops entries node =
  let entries =
    if List.exists (same_dirty_node ops node) entries then entries
    else (node, ops.dirty node) :: entries
  in
  mark_dirty t lane ops node;
  entries

let restore_dirty _t _lane ops entries =
  List.iter (fun (node, dirty) -> ops.dirty_set node dirty) entries

let generation t _lane = Eta_signal_graph_state.generation t.state
let set_generation t _lane generation =
  Eta_signal_graph_state.set_generation t.state generation

let advance_generation t =
  let exception Overflow in
  match
    Eta_signal_graph_state.advance_generation t.state ~advance:(fun generation ->
        if generation = max_int then raise Overflow else generation + 1)
  with
  | () -> Ok ()
  | exception Overflow -> Error (`Counter_overflow "stabilization generation")

let begin_staging t ~timer_refresh =
  Eta_signal_graph_state.begin_staging t.state ~timer_refresh

let drain_pending t = Eta_signal_graph_state.drain_pending t.state
let enqueue_pending t _lane pending =
  Eta_signal_graph_state.enqueue_pending t.state pending

let require_active_staging t = Eta_signal_graph_state.require_staging t.state

let remember_compute ops ~generation computed node =
  if ops.compute_computed_generation node = generation then computed
  else (
    ops.compute_set_computed_generation node generation;
    ops.compute_pack node :: computed)

let remember_computed t lane staging ops node =
  Eta_signal_graph_state.remember_computed t.state staging
    ~generation:(generation t lane) node ~project:ops.compute_node
    ~remember:(remember_compute ops)

let iter_computed t _lane staging ~f =
  if not (Eta_signal_graph_state.require_staging t.state == staging) then
    invalid_arg "Eta_signal graph staging token is not active";
  List.iter f (Eta_signal_graph_state.computed_nodes t.state)

let compute_seen t lane ops node =
  Int.equal (ops.compute_seen_generation node) (generation t lane)

let compute_changed_seen _t ops node = ops.compute_changed_seen node

let compute_run t lane ops node ~cycle ~compute =
  let generation = generation t lane in
  if ops.compute_computing node then cycle ()
  else (
    ops.compute_set_computing node true;
    match
      Fun.protect
        ~finally:(fun () -> ops.compute_set_computing node false)
        compute
    with
    | value, changed ->
        ops.compute_set_seen_generation node generation;
        ops.compute_set_changed_seen node changed;
        (value, changed))

let compute_cached t lane ops node ~current ~cycle ~compute =
  let compute_node = ops.compute_node node in
  if compute_seen t lane ops compute_node then
    (current compute_node, compute_changed_seen t ops compute_node)
  else
    compute_run t lane ops compute_node
      ~cycle:(fun () -> cycle compute_node)
      ~compute:(fun () -> compute compute_node)

let version_snapshot _t _lane ops nodes =
  List.map (fun node -> (version_id ops node, ops.version node)) nodes

let rec same_version_snapshot ops left right =
  match (left, right) with
  | [], [] -> true
  | (left_id, left_version) :: left_rest,
    (right_id, right_version) :: right_rest ->
      version_equal_id ops left_id right_id
      && Int.equal left_version right_version
      && same_version_snapshot ops left_rest right_rest
  | [], _ :: _ | _ :: _, [] -> false

let versions_changed t lane ops ~current nodes =
  not
    (same_version_snapshot ops current (version_snapshot t lane ops nodes))

let same_order_node ops left right =
  order_equal_id ops (order_id ops left) (order_id ops right)

let order_depends_on ops node dependency =
  let target_id = order_id ops dependency in
  let seen = Hashtbl.create 16 in
  let rec visit candidate =
    let candidate_id = order_id ops candidate in
    if order_equal_id ops candidate_id target_id then true
    else if Hashtbl.mem seen candidate_id then false
    else (
      Hashtbl.add seen candidate_id ();
      List.exists visit (ops.order_children candidate))
  in
  List.exists visit (ops.order_children node)

let compare_order _t _lane ops left right =
  if same_order_node ops left right then 0
  else if order_depends_on ops left right then 1
  else if order_depends_on ops right left then -1
  else ops.order_compare_id (order_id ops left) (order_id ops right)

let fold_reachable _t _lane ops ~roots ~init ~f =
  let seen = Hashtbl.create 16 in
  let rec visit acc node =
    let id = ops.reachable_id node in
    if (not (ops.reachable_valid node)) || Hashtbl.mem seen id then acc
    else (
      Hashtbl.add seen id ();
      List.fold_left visit (f acc node) (ops.reachable_children node))
  in
  List.fold_left visit init roots

type ('node, 'bind_node) bind_node_selection = {
  reachable_bind_node : 'node -> 'bind_node option;
}

let bind_node_selection ~bind = { reachable_bind_node = bind }

let collect_reachable_bind_nodes t lane ops ~roots selection =
  fold_reachable t lane ops ~roots ~init:[] ~f:(fun selected node ->
      match selection.reachable_bind_node node with
      | None -> selected
      | Some value -> value :: selected)

let collect_reachable_ids t lane ops ~roots =
  fold_reachable t lane ops ~roots ~init:(Hashtbl.create 16)
    ~f:(fun seen node ->
      Hashtbl.replace seen (ops.reachable_id node) ();
      seen)

let remember_staged_bind t _lane staging bind =
  Eta_signal_graph_state.stage_bind t.state staging bind

let stage_bind_switch t lane staging bind snapshot ~source_value ~inner ~scope =
  Eta_signal_bind.stage_transaction_switch
    (Eta_signal_stabilization.active_transaction t.stabilization)
    snapshot
    ~remember:(fun () -> remember_staged_bind t lane staging bind)
    ~source_value ~inner ~scope

let graph_error_of_bind_switch_error = function
  | `Invalid_scope -> (`Invalid_scope : Eta_signal_error.graph_error)

let map_bind_switch_result = function
  | Ok _ as ok -> ok
  | Error err -> Error (graph_error_of_bind_switch_error err)

let commit_staged_bind_switch switch lifecycle =
  Eta_signal_bind.commit_staged_switch switch lifecycle
  |> map_bind_switch_result

let rollback_staged_bind_switch ~staged lifecycle =
  Eta_signal_bind.rollback_staged_switch ~staged lifecycle
  |> map_bind_switch_result

type ('bind, 'scope, 'owner, 'acc) staged_bind_invalidation_plan = {
  staged_bind_invalidation_init : 'acc;
  staged_bind_invalidation_switch :
    'bind -> ('scope, 'owner) Eta_signal_bind.packed_staged_switch;
  staged_bind_invalidation_collect_old_scope :
    'acc -> owner:'owner -> 'scope -> 'acc;
}

let staged_bind_invalidation_plan ~init ~staged_switch ~collect_old_scope =
  {
    staged_bind_invalidation_init = init;
    staged_bind_invalidation_switch = staged_switch;
    staged_bind_invalidation_collect_old_scope = collect_old_scope;
  }

let collect_staged_bind_switch_invalidations t _lane _staging plan =
  Eta_signal_bind.collect_staged_switch_invalidations
    ~init:plan.staged_bind_invalidation_init
    ~switches:(Eta_signal_graph_state.staged_binds t.state)
    ~staged_switch:plan.staged_bind_invalidation_switch
    ~collect_old_scope:plan.staged_bind_invalidation_collect_old_scope
  |> map_bind_switch_result

let remember_pure_disposal_hooks t _lane staging hooks =
  Eta_signal_graph_state.remember_pure_disposal_hooks t.state staging hooks

let remember_timer_refresh_disposal_hooks t _lane staging hooks =
  Eta_signal_graph_state.remember_timer_refresh_disposal_hooks t.state staging
    hooks

let saturating_succ value =
  if value = max_int then max_int else value + 1

type ('bind, 'hook, 'timer, 'refresh) staging_reset_context = {
  staging_reset_rollback_bind :
    staging -> 'bind -> 'hook staged_bind_rollback;
  staging_reset_rollback_timer_refresh_dirty :
    staging -> 'refresh -> staged_timer_refresh_dirty_rollback;
  staging_reset_clear_timer_refresh_timer :
    staging -> 'timer -> staged_timer_reset;
}

and 'hook staged_bind_rollback =
  | Staged_bind_rollback : {
      staged_bind_rollback_snapshot :
        ('source, 'inner, 'scope) Eta_signal_bind.snapshot option;
      staged_bind_rollback_lifecycle :
        ('owner, 'inner, 'scope, 'hook)
        Eta_signal_bind.staged_switch_lifecycle;
    }
      -> 'hook staged_bind_rollback

and staged_timer_reset = Staged_timer_reset of { timer_reset : unit -> unit }

and staged_timer_refresh_dirty_rollback =
  | Staged_timer_refresh_dirty_rollback of {
      timer_refresh_dirty_rollback : unit -> unit;
    }

let staged_bind_rollback ~staged ~lifecycle =
  Staged_bind_rollback
    {
      staged_bind_rollback_snapshot = staged;
      staged_bind_rollback_lifecycle = lifecycle;
    }

let staged_timer_reset ~reset = Staged_timer_reset { timer_reset = reset }

let staged_timer_refresh_dirty_rollback ~rollback =
  Staged_timer_refresh_dirty_rollback
    { timer_refresh_dirty_rollback = rollback }

let staging_reset_context ~rollback_bind ~rollback_timer_refresh_dirty
    ~clear_timer_refresh_timer =
  {
    staging_reset_rollback_bind = rollback_bind;
    staging_reset_rollback_timer_refresh_dirty = rollback_timer_refresh_dirty;
    staging_reset_clear_timer_refresh_timer = clear_timer_refresh_timer;
  }

let rollback_staging_bind staging bind context =
  match context.staging_reset_rollback_bind staging bind with
  | Staged_bind_rollback
      {
        staged_bind_rollback_snapshot;
        staged_bind_rollback_lifecycle;
      } ->
      rollback_staged_bind_switch ~staged:staged_bind_rollback_snapshot
        staged_bind_rollback_lifecycle

let reset_staging_timer staging timer context =
  match context.staging_reset_clear_timer_refresh_timer staging timer with
  | Staged_timer_reset { timer_reset } -> timer_reset ()

let rollback_staging_timer_refresh_dirty staging refresh context =
  match
    context.staging_reset_rollback_timer_refresh_dirty staging refresh
  with
  | Staged_timer_refresh_dirty_rollback
      { timer_refresh_dirty_rollback } ->
      timer_refresh_dirty_rollback ()

let reset_staging t _lane staging context =
  let exception Rollback_error of Eta_signal_error.graph_error in
  let state_context =
    Eta_signal_graph_state.reset_context
      ~rollback_bind:(fun bind ->
        match rollback_staging_bind staging bind context with
        | Ok hooks -> hooks
        | Error err -> raise (Rollback_error err))
      ~rollback_transaction:(fun () ->
        Eta_signal_stabilization.rollback_transaction t.stabilization)
      ~rollback_timer_refresh_dirty:(fun refresh ->
        rollback_staging_timer_refresh_dirty staging refresh context)
      ~clear_timer_refresh_timer:(fun timer ->
        reset_staging_timer staging timer context)
  in
  Eta_signal_graph_state.reset_staging t.state staging state_context

type 'hook staged_bind_commit =
  | Staged_bind_commit : {
      staged_bind_switch :
        ('source, 'inner, 'scope, 'owner)
        Eta_signal_bind.staged_switch;
      staged_bind_lifecycle :
        ('owner, 'inner, 'scope, 'hook)
        Eta_signal_bind.staged_switch_lifecycle;
    }
      -> 'hook staged_bind_commit

let staged_bind_commit ~switch ~lifecycle =
  Staged_bind_commit
    { staged_bind_switch = switch; staged_bind_lifecycle = lifecycle }

type ('bind, 'hook) staging_bind_commit_plan = {
  staging_bind_commit : staging -> 'bind -> 'hook staged_bind_commit;
}

let staging_bind_commit_plan ~commit = { staging_bind_commit = commit }

let commit_staging_bind staging bind context =
  match context.staging_bind_commit staging bind with
  | Staged_bind_commit { staged_bind_switch; staged_bind_lifecycle } ->
      commit_staged_bind_switch staged_bind_switch staged_bind_lifecycle

type staged_signal_commit =
  | Staged_signal_commit : {
      signal_valid : bool;
      signal_cell : 'snapshot Eta_signal_transaction.staged;
      signal_commit : unit -> unit;
    }
      -> staged_signal_commit

let staged_signal_commit ~valid ~cell ~commit =
  Staged_signal_commit
    { signal_valid = valid; signal_cell = cell; signal_commit = commit }

type 'node staging_signal_commit_plan = {
  staging_signal_commit : staging -> 'node -> staged_signal_commit;
}

let staging_signal_commit_plan ~commit = { staging_signal_commit = commit }

let signal_staged_in_active_transaction t cell =
  match Eta_signal_stabilization.transaction t.stabilization with
  | Some transaction -> Eta_signal_transaction.staged transaction cell
  | None -> false

let prepare_staging_signal t _staging = function
  | Staged_signal_commit { signal_valid; signal_cell; _ } as commit ->
      if
        (not signal_valid)
        && signal_staged_in_active_transaction t signal_cell
      then
        Eta_signal_transaction.discard
          (Eta_signal_stabilization.active_transaction t.stabilization)
          signal_cell;
      commit

let commit_staging_signal = function
  | Staged_signal_commit { signal_valid; signal_commit; _ } ->
      if signal_valid then signal_commit ()

type staged_timer_commit = Staged_timer_commit of { timer_commit : unit -> unit }

let staged_timer_commit ~commit = Staged_timer_commit { timer_commit = commit }

type 'timer staging_timer_commit_plan = {
  staging_timer_commit : staging -> 'timer -> staged_timer_commit;
}

let staging_timer_commit_plan ~commit = { staging_timer_commit = commit }

let commit_staging_timer staging timer context =
  match context.staging_timer_commit staging timer with
  | Staged_timer_commit { timer_commit } -> timer_commit ()

type staged_preflight = Staged_preflight of { preflight : unit -> unit }

let staged_preflight ~preflight = Staged_preflight { preflight }

let run_staging_preflight staging preflight =
  match preflight staging with
  | Staged_preflight { preflight } -> preflight ()

type ('bind, 'node, 'hook, 'timer) staging_commit_plan = {
  staging_commit_preflight : staging -> staged_preflight;
  staging_commit_binds : ('bind, 'hook) staging_bind_commit_plan;
  staging_commit_signals : 'node staging_signal_commit_plan;
  staging_commit_timers : 'timer staging_timer_commit_plan;
}

let staging_commit_plan ~preflight ~binds ~signals ~timers =
  {
    staging_commit_preflight = preflight;
    staging_commit_binds = binds;
    staging_commit_signals = signals;
    staging_commit_timers = timers;
  }

let commit_staging t _lane staging context =
  let exception Commit_error of Eta_signal_error.graph_error in
  let state_plan =
    Eta_signal_graph_state.commit_plan
      ~preflight:(fun () ->
        run_staging_preflight staging context.staging_commit_preflight)
      ~binds:
        (Eta_signal_graph_state.bind_commit_plan
           ~commit:(fun bind ->
             match
               commit_staging_bind staging bind context.staging_commit_binds
             with
             | Ok hooks -> hooks
             | Error err -> raise (Commit_error err)))
      ~signals:
        (Eta_signal_graph_state.signal_commit_plan
           ~prepare_signal:(fun node ->
             context.staging_commit_signals.staging_signal_commit
               staging node
             |> prepare_staging_signal t staging)
           ~commit_signal:commit_staging_signal)
      ~timers:
        (Eta_signal_graph_state.timer_commit_plan
           ~commit:(fun timer ->
             commit_staging_timer staging timer
               context.staging_commit_timers))
      ~snapshot:
        (Eta_signal_graph_state.snapshot_commit_plan
           ~commit_transaction:(fun () ->
             match
               Eta_signal_stabilization.commit_transaction
                 t.stabilization
             with
             | Ok () -> ()
             | Error err -> raise (Commit_error err))
           ~advance_snapshot:saturating_succ)
  in
  try Ok (Eta_signal_graph_state.commit_staging t.state staging state_plan)
  with Commit_error err -> Error err

let pure_snapshot_commit_count t _lane =
  Eta_signal_graph_state.pure_snapshot_commit_count t.state

let set_pure_snapshot_commit_count t _lane count =
  Eta_signal_graph_state.set_pure_snapshot_commit_count t.state count

let active_transaction t =
  Eta_signal_stabilization.active_transaction t.stabilization

let read_effective t cell =
  match Eta_signal_stabilization.transaction t.stabilization with
  | Some transaction -> Eta_signal_transaction.read transaction cell
  | None -> Eta_signal_transaction.current cell

let stage_cell t _lane _staging cell value =
  Eta_signal_transaction.stage (active_transaction t) cell value

let update_cell t _lane _staging cell f =
  let transaction = active_transaction t in
  let value = Eta_signal_transaction.read transaction cell in
  Eta_signal_transaction.stage transaction cell (f value)

let staged_in_active_transaction t _lane _staging cell =
  match Eta_signal_stabilization.transaction t.stabilization with
  | Some transaction -> Eta_signal_transaction.staged transaction cell
  | None -> false

let staged_value t _lane _staging cell =
  match Eta_signal_stabilization.transaction t.stabilization with
  | Some transaction when Eta_signal_transaction.staged transaction cell ->
      Some (Eta_signal_transaction.read transaction cell)
  | Some _ | None -> None

let discard_staging t _lane _staging cell =
  match Eta_signal_stabilization.transaction t.stabilization with
  | Some transaction -> Eta_signal_transaction.discard transaction cell
  | None -> ()

let next_timer_refresh_token t _lane =
  let exception Overflow in
  match
    Eta_signal_graph_state.next_timer_refresh_token t.state
      ~advance:(fun token ->
        if token = max_int then raise Overflow else token + 1)
  with
  | token -> Ok token
  | exception Overflow -> Error (`Counter_overflow "timer refresh token")

let set_next_timer_refresh_token t _lane token =
  Eta_signal_graph_state.set_next_timer_refresh_token t.state token

let mark_timer_refresh_dirty t _lane _staging ~mark ~record =
  match Eta_signal_graph_state.active_timer_refresh t.state with
  | None -> mark ()
  | Some refresh -> record refresh

let timer_has_staged_refresh t timer ~refresh_token ~staged_token =
  match Eta_signal_graph_state.active_timer_refresh t.state with
  | Some refresh -> staged_token timer = refresh_token refresh
  | None -> false

let remember_timer_refresh_timer t _lane staging timer ~refresh_token
    ~staged_token ~set_staged_token ~stage_refresh_token =
  match Eta_signal_graph_state.active_timer_refresh t.state with
  | None -> ()
  | Some refresh ->
      let token = refresh_token refresh in
      if staged_token timer <> token then (
        set_staged_token timer token;
        stage_refresh_token timer token;
        Eta_signal_graph_state.stage_timer_refresh_timer t.state staging timer)

let with_timer_refresh_timer t _lane timer ~none ~some =
  match (Eta_signal_graph_state.active_timer_refresh t.state, timer) with
  | Some refresh, Some timer -> some refresh timer
  | None, _ | Some _, None -> none ()

let allocation_scope t ops =
  match Eta_signal_stabilization.state t.stabilization with
  | Idle -> Ok (ops.scope_current t.current_scope)
  | Pure -> (
      match ops.scope_require_valid_current t.current_scope with
      | Ok scope -> Ok (Some scope)
      | Error `Ambiguous_scope -> Error `Ambiguous_scope)
  | Committed | Delivering -> Error `Ambiguous_scope

let with_current_scope t ops scope f =
  ops.scope_with_current t.current_scope scope f

let ensure_not_pure t =
  if Eta_signal_stabilization.is_pure t.stabilization then
    Error `Ambiguous_scope
  else Ok ()

let stream_bridge_metrics t = t.stream_bridge_metrics
let set_stream_bridge_metrics t _lane metrics = t.stream_bridge_metrics <- metrics
let add_observer t _lane observer = t.observers <- observer :: t.observers

type 'observer observer_identity = {
  observer_same : 'observer -> 'observer -> bool;
}

let observer_identity ~same = { observer_same = same }

let remove_observer t _lane identity observer =
  t.observers <-
    List.filter
      (fun candidate -> not (identity.observer_same candidate observer))
      t.observers

type ('observer, 'hook) observer_cleanup = {
  observer_cleanup_selected : 'observer -> bool;
  observer_cleanup_hooks : 'observer -> 'hook list;
}

let observer_cleanup ~selected ~cleanup =
  {
    observer_cleanup_selected = selected;
    observer_cleanup_hooks = cleanup;
  }

let collect_observer_cleanup_hooks t _lane cleanup =
  t.observers
  |> List.filter cleanup.observer_cleanup_selected
  |> List.concat_map cleanup.observer_cleanup_hooks

type observer_counts = {
  active_count : int;
  invalid_count : int;
}

type 'observer observer_count_plan = {
  observer_count_active : 'observer -> bool;
  observer_count_invalid : 'observer -> bool;
}

let observer_count_plan ~active ~invalid =
  { observer_count_active = active; observer_count_invalid = invalid }

let increment_count count = if count = max_int then max_int else count + 1

let observer_counts t _lane plan =
  List.fold_left
    (fun counts observer ->
      {
        active_count =
          (if plan.observer_count_active observer then
             increment_count counts.active_count
           else counts.active_count);
        invalid_count =
          (if plan.observer_count_invalid observer then
             increment_count counts.invalid_count
           else counts.invalid_count);
      })
    { active_count = 0; invalid_count = 0 }
    t.observers

let observer_counts_active counts = counts.active_count
let observer_counts_invalid counts = counts.invalid_count

type ('observer, 'diagnostic) observer_diagnostics = {
  observer_diagnostic_visible : 'observer -> bool;
  observer_diagnostic_value : 'observer -> 'diagnostic;
}

let observer_diagnostics ~visible ~diagnostic =
  {
    observer_diagnostic_visible = visible;
    observer_diagnostic_value = diagnostic;
  }

let collect_observer_diagnostics t _lane diagnostics =
  List.filter_map
    (fun observer ->
      if diagnostics.observer_diagnostic_visible observer then
        Some (diagnostics.observer_diagnostic_value observer)
      else None)
    t.observers

let observer_delivery_plan t _lane delivery =
  Eta_signal_observer.delivery_plan delivery ~observers:t.observers
    ~capability:Eta_signal_stabilization_pass.pure_capability
    ~make_plan:Eta_signal_stabilization_pass.observer_plan

type 'pending stabilization_pending_plan = {
  pending_release_marks :
    lane_access -> 'pending list -> stabilization_pending_mark_release;
  pending_stage :
    lane_access -> staging -> 'pending list -> stabilization_pending_stage;
}

and stabilization_pending_mark_release =
  | Stabilization_pending_mark_release of {
      release_pending_marks : unit -> unit;
    }

and stabilization_pending_stage =
  | Stabilization_pending_stage of { stage_pending : unit -> unit }

let stabilization_pending_mark_release ~release =
  Stabilization_pending_mark_release { release_pending_marks = release }

let stabilization_pending_stage ~stage =
  Stabilization_pending_stage { stage_pending = stage }

let stabilization_pending_plan ~release_marks ~stage =
  { pending_release_marks = release_marks; pending_stage = stage }

let run_stabilization_pending_mark_release lane pending plan =
  match plan lane pending with
  | Stabilization_pending_mark_release { release_pending_marks } ->
      release_pending_marks ()

let run_stabilization_pending_stage lane staging pending plan =
  match plan lane staging pending with
  | Stabilization_pending_stage { stage_pending } -> stage_pending ()

type ('observer, 'event) stabilization_observer_plan = {
  observer_delivery :
    lane_access ->
    staging ->
    (lane_access, 'observer, 'event) Eta_signal_observer.delivery_collection;
  observer_plan_staged_binds :
    lane_access -> staging -> 'observer list -> staged_bind_planning;
}

and staged_bind_planning =
  | Staged_bind_planning of { plan_staged_binds : unit -> unit }

let staged_bind_planning ~plan =
  Staged_bind_planning { plan_staged_binds = plan }

let stabilization_observer_plan ~delivery ~plan_staged_binds =
  {
    observer_delivery = delivery;
    observer_plan_staged_binds = plan_staged_binds;
  }

let run_staged_bind_planning = function
  | Staged_bind_planning { plan_staged_binds } -> plan_staged_binds ()

type ('bind, 'node, 'hook, 'timer) stabilization_commit_plan = {
  stabilization_commit_staging_plan :
    lane_access -> staging -> ('bind, 'node, 'hook, 'timer) staging_commit_plan;
  stabilization_update_necessity : lane_access -> stabilization_necessity_update;
}

and stabilization_necessity_update =
  | Stabilization_necessity_update of { update_necessity : unit -> unit }

let stabilization_necessity_update ~update =
  Stabilization_necessity_update { update_necessity = update }

let stabilization_commit_plan ~staging ~update_necessity =
  {
    stabilization_commit_staging_plan = staging;
    stabilization_update_necessity = update_necessity;
  }

let run_stabilization_necessity_update lane plan =
  match plan lane with
  | Stabilization_necessity_update { update_necessity } ->
      update_necessity ()

type
  ( 'pending,
    'bind,
    'node,
    'observer,
    'event,
    'hook,
    'timer )
  stabilization_pure =
  {
    pending_plan : 'pending stabilization_pending_plan;
    observer_plan : ('observer, 'event) stabilization_observer_plan;
    commit_plan : ('bind, 'node, 'hook, 'timer) stabilization_commit_plan;
  }

let stabilization_pure_ops ~pending ~observers ~commit =
  { pending_plan = pending; observer_plan = observers; commit_plan = commit }

type
  ( 'pending,
    'bind,
    'observer,
    'hook,
    'timer,
    'refresh )
  stabilization_rollback =
  {
    rollback_staging_context :
      lane_access ->
      staging ->
      ('bind, 'hook, 'timer, 'refresh) staging_reset_context;
    mark_observers_failed_without_current :
      lane_access -> 'observer list -> stabilization_observer_failure_mark;
    requeue_pending : lane_access -> 'pending list -> stabilization_pending_requeue;
  }

and stabilization_pending_requeue =
  | Stabilization_pending_requeue of { requeue_pending : unit -> unit }

and stabilization_observer_failure_mark =
  | Stabilization_observer_failure_mark of {
      mark_observers_failed_without_current : unit -> unit;
    }

let stabilization_pending_requeue ~requeue =
  Stabilization_pending_requeue { requeue_pending = requeue }

let stabilization_observer_failure_mark ~mark =
  Stabilization_observer_failure_mark
    { mark_observers_failed_without_current = mark }

let stabilization_rollback_ops ~staging
    ~mark_observers_failed_without_current ~requeue_pending =
  {
    rollback_staging_context = staging;
    mark_observers_failed_without_current;
    requeue_pending;
  }

let run_stabilization_pending_requeue lane pending plan =
  match plan lane pending with
  | Stabilization_pending_requeue { requeue_pending } ->
      requeue_pending ()

let run_stabilization_observer_failure_mark lane observers plan =
  match plan lane observers with
  | Stabilization_observer_failure_mark
      { mark_observers_failed_without_current } ->
      mark_observers_failed_without_current ()

type
  ( 'pending,
    'bind,
    'node,
    'observer,
    'event,
    'hook,
    'timer,
    'refresh )
  stabilization_ops =
  {
    classify_graph_error : exn -> Eta_signal_error.graph_error option;
    pure :
      ( 'pending,
        'bind,
        'node,
        'observer,
        'event,
        'hook,
        'timer )
      stabilization_pure;
    rollback :
      ( 'pending,
        'bind,
        'observer,
        'hook,
        'timer,
        'refresh )
      stabilization_rollback;
  }

let stabilization_ops ~classify_graph_error ~pure ~rollback =
  { classify_graph_error; pure; rollback }

exception Graph_phase_error of Eta_signal_error.graph_error

let pass_errors ops =
  Eta_signal_stabilization_pass.errors
    ~reentrant_stabilization:`Reentrant_stabilization
    ~classify_graph_error:(function
      | Graph_phase_error err -> Some err
      | exn -> ops.classify_graph_error exn)

let pass_pure t timer_refresh pure =
  let generation =
    Eta_signal_stabilization_pass.pure_generation_plan
      ~advance_generation:(fun _context ->
      match advance_generation t with
      | Ok () -> ()
      | Error err -> raise (Graph_phase_error err))
  in
  let staging =
    Eta_signal_stabilization_pass.pure_staging_plan
      ~begin_staging:(fun _context -> begin_staging t ~timer_refresh)
  in
  let pending =
    Eta_signal_stabilization_pass.pure_pending_plan
      ~drain_pending:(fun _context -> drain_pending t)
      ~release_pending_marks:(fun context pending ->
        run_stabilization_pending_mark_release
          (Eta_signal_stabilization_pass.pure_capability context)
          pending pure.pending_plan.pending_release_marks)
      ~stage_pending:(fun context pending ->
        run_stabilization_pending_stage
          (Eta_signal_stabilization_pass.pure_capability context)
          (require_active_staging t)
          pending pure.pending_plan.pending_stage)
  in
  let observers =
    Eta_signal_stabilization_pass.pure_observer_plan
      ~observer_plan:(fun context ->
        let lane = Eta_signal_stabilization_pass.pure_capability context in
        let staging = require_active_staging t in
        let delivery =
          pure.observer_plan.observer_delivery lane staging
        in
        observer_delivery_plan t lane delivery)
      ~plan_staged_binds:(fun context observers ->
        let plan =
          pure.observer_plan.observer_plan_staged_binds
            (Eta_signal_stabilization_pass.pure_capability context)
            (require_active_staging t)
            observers
        in
        run_staged_bind_planning plan)
  in
  let commit =
    Eta_signal_stabilization_pass.pure_commit_plan
      ~commit_staging:(fun context staging ->
        let lane = Eta_signal_stabilization_pass.pure_capability context in
        let plan =
          pure.commit_plan.stabilization_commit_staging_plan lane staging
        in
        match commit_staging t lane staging plan with
        | Ok hooks -> hooks
        | Error err -> raise (Graph_phase_error err))
      ~update_necessity:(fun context ->
        run_stabilization_necessity_update
          (Eta_signal_stabilization_pass.pure_capability context)
          pure.commit_plan.stabilization_update_necessity)
  in
  Eta_signal_stabilization_pass.pure_ops ~generation ~staging ~pending
    ~observers ~commit

let pass_rollback t rollback =
  let staging =
    Eta_signal_stabilization_pass.rollback_staging_plan
      ~rollback_staging:(fun context staging ->
        let lane =
          Eta_signal_stabilization_pass.rollback_capability context
        in
        let reset_context =
          rollback.rollback_staging_context lane staging
        in
        reset_staging t lane staging reset_context)
  in
  let observers =
    Eta_signal_stabilization_pass.rollback_observer_plan
      ~mark_observers_failed_without_current:
      (fun context observers ->
        run_stabilization_observer_failure_mark
          (Eta_signal_stabilization_pass.rollback_capability context)
          observers rollback.mark_observers_failed_without_current)
  in
  let pending =
    Eta_signal_stabilization_pass.rollback_pending_plan
      ~requeue_pending:(fun context pending ->
        run_stabilization_pending_requeue
          (Eta_signal_stabilization_pass.rollback_capability context)
          pending rollback.requeue_pending)
  in
  Eta_signal_stabilization_pass.rollback_ops ~staging ~observers ~pending

let clear_timer_refresh t _context =
  Eta_signal_graph_state.clear_active_timer_refresh t.state

let run_stabilization t capability ~timer_refresh ops =
  Eta_signal_stabilization_pass.run t.stabilization capability
    (Eta_signal_stabilization_pass.pass_ops ~errors:(pass_errors ops)
       ~pure:(pass_pure t timer_refresh ops.pure)
       ~rollback:(pass_rollback t ops.rollback)
       ~timer_refresh:
         (Eta_signal_stabilization_pass.timer_refresh_ops
            ~clear_active_timer_refresh:(clear_timer_refresh t)))

let finish_stabilization t _lane delivering_token =
  Eta_signal_graph_state.clear_active_timer_refresh t.state;
  ignore
    (Eta_signal_stabilization.finish_delivering t.stabilization
       delivering_token
      : (_, Eta_signal_stabilization.idle) Eta_signal_stabilization.token)

type 'owner stabilization_finish = {
  mutable delivering_token :
    ('owner, Eta_signal_stabilization.delivering)
    Eta_signal_stabilization.token
    option;
}

let create_stabilization_finish () = { delivering_token = None }

let record_stabilization_result finish _lane result =
  Eta_signal_stabilization_pass.result result
    ~pure_ok:(fun ~hooks ~events:_ ~delivering_token ->
      finish.delivering_token <- Some delivering_token;
      hooks)
    ~graph_error:(fun ~hooks _ -> hooks)
    ~defect:(fun ~hooks _ _ -> hooks)

let stabilization_finish_pending finish =
  Option.is_some finish.delivering_token

let finish_recorded_stabilization t lane finish =
  match finish.delivering_token with
  | None -> ()
  | Some delivering_token ->
      finish.delivering_token <- None;
      finish_stabilization t lane delivering_token

type ('event, 'error) stabilization_delivery_context = {
  delivery_run_pending_cleanup : unit -> (unit, 'error) Eta.Effect.t;
  delivery_run_events : 'event list -> (unit, 'error) Eta.Effect.t;
  delivery_with_lane_access :
    (lane_access -> unit) -> (unit, 'error) Eta.Effect.t;
}

let stabilization_delivery_context ~run_pending_cleanup ~run_events
    ~with_lane_access =
  {
    delivery_run_pending_cleanup = run_pending_cleanup;
    delivery_run_events = run_events;
    delivery_with_lane_access = with_lane_access;
  }

let finish_recorded_stabilization_effect t finish context =
  if stabilization_finish_pending finish then
    context.delivery_with_lane_access (fun lane ->
        finish_recorded_stabilization t lane finish)
  else Eta.Effect.unit

let stabilization_delivery_ops t finish context =
  let cleanup =
    Eta_signal_stabilization_pass.delivery_cleanup_plan
      ~run_pending_cleanup:context.delivery_run_pending_cleanup
      ~finish:(fun () ->
        finish_recorded_stabilization_effect t finish context)
  in
  let events =
    Eta_signal_stabilization_pass.delivery_event_plan
      ~run_events:context.delivery_run_events
      ~mark_complete:(fun () ->
        context.delivery_with_lane_access (fun lane ->
            bump_counter t lane Callback_delivery_count))
  in
  Eta_signal_stabilization_pass.delivery_ops ~cleanup ~events

let max_dead_node_tombstones = 1024

let same_signal_id left right =
  Eta_signal_id.signal_int left = Eta_signal_id.signal_int right

let remember_dead_node t _lane ~id dead_node =
  t.dead_nodes <-
    Eta_signal_debug.remember_latest
      ~max_count:max_dead_node_tombstones
      ~id ~equal_id:same_signal_id dead_node t.dead_nodes

let collect_live_node_registry t ~collect_live_nodes ~keep =
  let cells, nodes = collect_live_nodes keep t.all_nodes in
  t.all_nodes <- cells;
  nodes

let remember_live_node t ~create_weak_node node =
  t.all_nodes <- create_weak_node node :: t.all_nodes

let create_live_node t scope_ops lifecycle ~dependencies =
  ensure_context t;
  List.iter lifecycle.node_validate_dependency dependencies;
  match next_signal_id t with
  | Error _ as error -> error
  | Ok id -> (
      match allocation_scope t scope_ops with
      | Error _ as error -> error
      | Ok scope ->
          let node = lifecycle.node_create ~id ~scope in
          List.iter
            (fun child ->
              lifecycle.node_attach_dependency ~parent:node ~child)
            dependencies;
          Option.iter (fun scope -> lifecycle.node_add_to_scope scope node) scope;
          remember_live_node t
            ~create_weak_node:lifecycle.node_create_weak
            (lifecycle.node_pack node);
          Ok node)

let rec invalidate_live_node t lane edge_ops lifecycle ~invalidate_scope node =
  if lifecycle.invalidation_valid node then (
    let timer_hooks = lifecycle.invalidation_timer_hooks node in
    lifecycle.invalidation_set_invalid node;
    let tombstone = lifecycle.invalidation_tombstone node in
    remember_dead_node t lane ~id:lifecycle.invalidation_tombstone_id tombstone;
    let observer_hooks = lifecycle.invalidation_observer_hooks node in
    let _dependencies, dependents = detach_node_edges t lane edge_ops node in
    let dependent_hooks =
      List.concat_map
        (invalidate_live_node t lane edge_ops lifecycle ~invalidate_scope)
        dependents
    in
    let kind_hooks =
      lifecycle.invalidation_kind_hooks ~invalidate_scope node
    in
    timer_hooks @ observer_hooks @ dependent_hooks @ kind_hooks)
  else []

type ('node, 'weak_node) live_node_registry = {
  registry_collect_live_nodes :
    ('node -> bool) -> 'weak_node list -> 'weak_node list * 'node list;
}

let live_node_registry ~collect_live_nodes =
  { registry_collect_live_nodes = collect_live_nodes }

let live_nodes t _lane registry =
  collect_live_node_registry t
    ~collect_live_nodes:registry.registry_collect_live_nodes
    ~keep:(fun _ -> true)

let prune_live_nodes t _lane registry ~keep =
  ignore
    (collect_live_node_registry t
       ~collect_live_nodes:registry.registry_collect_live_nodes ~keep
      : _ list)

type necessary_snapshot = (Eta_signal_id.signal, unit) Hashtbl.t

let necessary_count snapshot = Hashtbl.length snapshot
let necessary_mem snapshot id = Hashtbl.mem snapshot id

type ('observer, 'node) demand_roots = {
  demand_root_demands : 'observer -> bool;
  demand_root_node : 'observer -> 'node;
}

let demand_roots ~demand ~root =
  { demand_root_demands = demand; demand_root_node = root }

type ('observer, 'node, 'weak_node) reachable_plan = {
  reachable_plan_ops : (Eta_signal_id.signal, 'node) reachable_ops;
  reachable_plan_registry : ('node, 'weak_node) live_node_registry;
  reachable_plan_roots : ('observer, 'node) demand_roots;
}

let reachable_plan ~ops ~registry ~roots =
  {
    reachable_plan_ops = ops;
    reachable_plan_registry = registry;
    reachable_plan_roots = roots;
  }

let demand_root_nodes roots observers =
  List.filter_map
    (fun observer ->
      if roots.demand_root_demands observer then
        Some (roots.demand_root_node observer)
      else None)
    observers

let reachable_live_nodes t lane plan =
  live_nodes t lane plan.reachable_plan_registry

let reachable_root_nodes t plan =
  demand_root_nodes plan.reachable_plan_roots t.observers

let necessary_ids t lane plan =
  ignore (reachable_live_nodes t lane plan : _ list);
  collect_reachable_ids t lane plan.reachable_plan_ops
    ~roots:(reachable_root_nodes t plan)

let update_necessity t lane plan =
  let next = necessary_ids t lane plan in
  Eta_signal_graph_core.update_necessary_ids t.core lane next;
  next

type 'timer timer_demand = {
  timer_demand_necessary_ids : necessary_snapshot;
  timer_demand_timers : (Eta_signal_id.signal * 'timer) list;
}

type ('observer, 'node, 'weak_node, 'timer) timer_demand_source = {
  timer_demand_reachable : ('observer, 'node, 'weak_node) reachable_plan;
  timer_demand_select : 'node -> (Eta_signal_id.signal * 'timer) option;
}

let timer_demand_source ~reachable ~timer =
  { timer_demand_reachable = reachable; timer_demand_select = timer }

let timer_demand t lane source =
  let reachable = source.timer_demand_reachable in
  let nodes = reachable_live_nodes t lane reachable in
  {
    timer_demand_necessary_ids =
      collect_reachable_ids t lane reachable.reachable_plan_ops
        ~roots:(reachable_root_nodes t reachable);
    timer_demand_timers = List.filter_map source.timer_demand_select nodes;
  }

let timer_demand_plan demand ~plan =
  plan
    ~is_necessary:(necessary_mem demand.timer_demand_necessary_ids)
    ~timers:demand.timer_demand_timers

let post_commit_necessary_timers t lane source =
  let reachable = source.timer_demand_reachable in
  ignore (reachable_live_nodes t lane reachable : _ list);
  fold_reachable t lane reachable.reachable_plan_ops
    ~roots:(reachable_root_nodes t reachable)
    ~init:(Hashtbl.create 8)
    ~f:(fun timers node ->
      Option.iter
        (fun (id, timer) -> Hashtbl.replace timers id timer)
        (source.timer_demand_select node);
      timers)

let dead_node_count t _lane = List.length t.dead_nodes
let iter_dead_nodes t _lane ~f = List.iter f t.dead_nodes
let map_dead_nodes t _lane ~f = List.map f t.dead_nodes
