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

type counter =
  | Callback_delivery_count
  | Recompute_count
  | Dynamic_scope_invalidations
  | Nodes_became_necessary
  | Nodes_became_unnecessary

type staging = Eta_signal_graph_state.staging

type ('id, 'node) edge_ops = {
  edge_id : 'node -> 'id;
  edge_equal_id : 'id -> 'id -> bool;
  edge_dependencies : 'node -> 'node list;
  edge_set_dependencies : 'node -> 'node list -> unit;
  edge_dependents : 'node -> 'node list;
  edge_set_dependents : 'node -> 'node list -> unit;
}

type ('id, 'node) dirty_ops = {
  dirty_id : 'node -> 'id;
  dirty_equal_id : 'id -> 'id -> bool;
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
  version_id : 'node -> 'id;
  version_equal_id : 'id -> 'id -> bool;
  version : 'node -> int;
}

type ('id, 'node) order_ops = {
  order_id : 'node -> 'id;
  order_equal_id : 'id -> 'id -> bool;
  order_compare_id : 'id -> 'id -> int;
  order_children : 'node -> 'node list;
}

type ('scope_context, 'scope) scope_ops = {
  scope_current : 'scope_context -> 'scope option;
  scope_require_valid_current :
    'scope_context -> ('scope, [ `Ambiguous_scope ]) result;
  scope_with_current : 'a. 'scope_context -> 'scope -> (unit -> 'a) -> 'a;
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

let with_lane_access t ~leaf_name ~depth_local ~hooks ~after_acquired f =
  let hooks =
    {
      Eta_signal_graph_core.note_waiter_enqueued =
        hooks.note_waiter_enqueued;
      note_waiter_compaction = hooks.note_waiter_compaction;
    }
  in
  Eta_signal_graph_core.with_lane_access t.core ~leaf_name ~depth_local
    ~hooks ~after_acquired f

let lane_waiting_count t = Eta_signal_graph_core.lane_waiting_count t.core
let lane_cancelled_count t = Eta_signal_graph_core.lane_cancelled_count t.core
let next_signal_id t = Eta_signal_graph_core.next_signal_id t.core
let next_var_id t = Eta_signal_graph_core.next_var_id t.core
let next_observer_id t = Eta_signal_graph_core.next_observer_id t.core
let next_scope_id t = Eta_signal_graph_core.next_scope_id t.core
let set_next_node_id t next = Eta_signal_graph_core.set_next_node_id t.core next

let set_next_scope_id t next =
  Eta_signal_graph_core.set_next_scope_id t.core next

let counter t target = Eta_signal_graph_core.counter t.core (core_counter target)

let set_counter t target value =
  Eta_signal_graph_core.set_counter t.core (core_counter target) value

let bump_counter t lane target =
  Eta_signal_graph_core.bump_counter t.core lane (core_counter target)

let remove_by_id ops id node =
  not (ops.edge_equal_id (ops.edge_id node) id)

let has_id ops id node =
  ops.edge_equal_id (ops.edge_id node) id

let remove_dependent _t ops ~child ~parent =
  ops.edge_set_dependents child
    (List.filter
       (remove_by_id ops (ops.edge_id parent))
       (ops.edge_dependents child))

let detach_dependency t ops ~parent ~child =
  remove_dependent t ops ~child ~parent;
  ops.edge_set_dependencies parent
    (List.filter
       (remove_by_id ops (ops.edge_id child))
       (ops.edge_dependencies parent))

let has_dependency _t ops ~parent ~child =
  List.exists
    (has_id ops (ops.edge_id child))
    (ops.edge_dependencies parent)

let has_dependent _t ops ~child ~parent =
  List.exists
    (has_id ops (ops.edge_id parent))
    (ops.edge_dependents child)

let attach_dependency t ops ~parent ~child =
  if not (has_dependent t ops ~child ~parent) then
    ops.edge_set_dependents child (parent :: ops.edge_dependents child);
  if not (has_dependency t ops ~parent ~child) then
    ops.edge_set_dependencies parent (child :: ops.edge_dependencies parent)

let mark_dirty _t ops node = ops.dirty_set node true

let same_dirty_node ops node (candidate, _) =
  ops.dirty_equal_id (ops.dirty_id node) (ops.dirty_id candidate)

let mark_dirty_recording_previous t ops entries node =
  let entries =
    if List.exists (same_dirty_node ops node) entries then entries
    else (node, ops.dirty node) :: entries
  in
  mark_dirty t ops node;
  entries

let restore_dirty _t ops entries =
  List.iter (fun (node, dirty) -> ops.dirty_set node dirty) entries

let generation t = Eta_signal_graph_state.generation t.state
let set_generation t generation = Eta_signal_graph_state.set_generation t.state generation

let advance_generation t ~advance =
  Eta_signal_graph_state.advance_generation t.state ~advance

let begin_staging t ~timer_refresh =
  Eta_signal_graph_state.begin_staging t.state ~timer_refresh

let drain_pending t = Eta_signal_graph_state.drain_pending t.state
let enqueue_pending t pending = Eta_signal_graph_state.enqueue_pending t.state pending

let active_staging t = Eta_signal_graph_state.require_staging t.state

let remember_compute ops ~generation computed node =
  if ops.compute_computed_generation node = generation then computed
  else (
    ops.compute_set_computed_generation node generation;
    ops.compute_pack node :: computed)

let remember_computed t ops node =
  Eta_signal_graph_state.remember_computed t.state (active_staging t)
    ~generation:(generation t) node ~project:ops.compute_node
    ~remember:(remember_compute ops)

let computed_nodes t = Eta_signal_graph_state.computed_nodes t.state

let compute_seen t ops node =
  Int.equal (ops.compute_seen_generation node) (generation t)

let compute_changed_seen _t ops node = ops.compute_changed_seen node

let compute_run t ops node ~cycle ~compute =
  let generation = generation t in
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

let version_snapshot _t ops nodes =
  List.map (fun node -> (ops.version_id node, ops.version node)) nodes

let rec same_version_snapshot ops left right =
  match (left, right) with
  | [], [] -> true
  | (left_id, left_version) :: left_rest,
    (right_id, right_version) :: right_rest ->
      ops.version_equal_id left_id right_id
      && Int.equal left_version right_version
      && same_version_snapshot ops left_rest right_rest
  | [], _ :: _ | _ :: _, [] -> false

let versions_changed t ops ~current nodes =
  not (same_version_snapshot ops current (version_snapshot t ops nodes))

let same_order_node ops left right =
  ops.order_equal_id (ops.order_id left) (ops.order_id right)

let order_depends_on ops node dependency =
  let target_id = ops.order_id dependency in
  let seen = Hashtbl.create 16 in
  let rec visit candidate =
    let candidate_id = ops.order_id candidate in
    if ops.order_equal_id candidate_id target_id then true
    else if Hashtbl.mem seen candidate_id then false
    else (
      Hashtbl.add seen candidate_id ();
      List.exists visit (ops.order_children candidate))
  in
  List.exists visit (ops.order_children node)

let compare_order _t ops left right =
  if same_order_node ops left right then 0
  else if order_depends_on ops left right then 1
  else if order_depends_on ops right left then -1
  else ops.order_compare_id (ops.order_id left) (ops.order_id right)

let remember_staged_bind t bind =
  Eta_signal_graph_state.stage_bind t.state (active_staging t) bind

let staged_binds t = Eta_signal_graph_state.staged_binds t.state

let remember_pure_disposal_hooks t hooks =
  Eta_signal_graph_state.remember_pure_disposal_hooks t.state
    (active_staging t) hooks

let remember_timer_refresh_disposal_hooks t hooks =
  Eta_signal_graph_state.remember_timer_refresh_disposal_hooks t.state
    (active_staging t) hooks

let reset_staging t staging ~rollback_bind ~rollback_transaction
    ~rollback_timer_refresh_dirty ~clear_timer_refresh_timer =
  Eta_signal_graph_state.reset_staging t.state staging ~rollback_bind
    ~rollback_transaction ~rollback_timer_refresh_dirty
    ~clear_timer_refresh_timer

let commit_staging t staging ~preflight ~commit_bind ~prepare_signal
    ~commit_transaction ~commit_timer_refresh ~commit_signal
    ~advance_snapshot =
  Eta_signal_graph_state.commit_staging t.state staging ~preflight
    ~commit_bind ~prepare_signal ~commit_transaction ~commit_timer_refresh
    ~commit_signal ~advance_snapshot

let pure_snapshot_commit_count t =
  Eta_signal_graph_state.pure_snapshot_commit_count t.state

let set_pure_snapshot_commit_count t count =
  Eta_signal_graph_state.set_pure_snapshot_commit_count t.state count

let active_transaction t =
  Eta_signal_stabilization.active_transaction t.stabilization

let active_pure_transaction = active_transaction

let commit_transaction t =
  Eta_signal_stabilization.commit_transaction t.stabilization

let rollback_transaction t =
  Eta_signal_stabilization.rollback_transaction t.stabilization

let read_effective t cell =
  match Eta_signal_stabilization.transaction t.stabilization with
  | Some transaction -> Eta_signal_transaction.read transaction cell
  | None -> Eta_signal_transaction.current cell

let stage_cell t cell value =
  Eta_signal_transaction.stage (active_transaction t) cell value

let update_cell t cell f =
  let transaction = active_transaction t in
  let value = Eta_signal_transaction.read transaction cell in
  Eta_signal_transaction.stage transaction cell (f value)

let staged_in_active_transaction t cell =
  match Eta_signal_stabilization.transaction t.stabilization with
  | Some transaction -> Eta_signal_transaction.staged transaction cell
  | None -> false

let staged_value t cell =
  match Eta_signal_stabilization.transaction t.stabilization with
  | Some transaction when Eta_signal_transaction.staged transaction cell ->
      Some (Eta_signal_transaction.read transaction cell)
  | Some _ | None -> None

let discard_staging t cell =
  match Eta_signal_stabilization.transaction t.stabilization with
  | Some transaction -> Eta_signal_transaction.discard transaction cell
  | None -> ()

let next_timer_refresh_token t ~advance =
  Eta_signal_graph_state.next_timer_refresh_token t.state ~advance

let set_next_timer_refresh_token t token =
  Eta_signal_graph_state.set_next_timer_refresh_token t.state token

let mark_timer_refresh_dirty t ~mark ~record =
  match Eta_signal_graph_state.active_timer_refresh t.state with
  | None -> mark ()
  | Some refresh -> record refresh

let timer_has_staged_refresh t timer ~refresh_token ~staged_token =
  match Eta_signal_graph_state.active_timer_refresh t.state with
  | Some refresh -> staged_token timer = refresh_token refresh
  | None -> false

let remember_timer_refresh_timer t timer ~refresh_token ~staged_token
    ~set_staged_token ~stage_refresh_token =
  match Eta_signal_graph_state.active_timer_refresh t.state with
  | None -> ()
  | Some refresh ->
      let token = refresh_token refresh in
      if staged_token timer <> token then (
        set_staged_token timer token;
        stage_refresh_token timer token;
        Eta_signal_graph_state.stage_timer_refresh_timer t.state
          (Eta_signal_graph_state.require_staging t.state)
          timer)

let with_timer_refresh_timer t timer ~none ~some =
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
let set_stream_bridge_metrics t metrics = t.stream_bridge_metrics <- metrics
let add_observer t observer = t.observers <- observer :: t.observers
let remove_observers t ~keep = t.observers <- List.filter keep t.observers
let matching_observers t ~selected = List.filter selected t.observers

let count_observers t ~selected =
  List.fold_left
    (fun count observer ->
      if selected observer then
        if count = max_int then max_int else count + 1
      else count)
    0 t.observers

let filter_map_observers t ~f = List.filter_map f t.observers

let observer_delivery_plan t ~active ~compare ~collect_event ~mark_pending =
  let observers = List.filter active t.observers in
  Eta_signal_stabilization_pass.observer_plan ~observers
    ~collect_events:
      (fun context observers ->
        let capability =
          Eta_signal_stabilization_pass.pure_capability context
        in
        observers |> List.sort compare
        |> List.filter_map (collect_event capability))
    ~mark_events_pending:
      (fun context events ->
        let capability =
          Eta_signal_stabilization_pass.pure_capability context
        in
        List.iter (mark_pending capability) events)

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

let clear_timer_refresh t _context =
  Eta_signal_graph_state.clear_active_timer_refresh t.state

let run_stabilization t capability ops =
  Eta_signal_stabilization_pass.run t.stabilization capability
    {
      errors = ops.errors;
      pure = ops.pure;
      rollback = ops.rollback;
      timer_refresh =
        {
          Eta_signal_stabilization_pass.clear_active_timer_refresh =
            clear_timer_refresh t;
        };
    }

let finish_stabilization t delivering_token =
  Eta_signal_graph_state.clear_active_timer_refresh t.state;
  ignore
    (Eta_signal_stabilization.finish_delivering t.stabilization
       delivering_token
      : (_, Eta_signal_stabilization.idle) Eta_signal_stabilization.token)

let collect_live_node_registry t ~collect_live_nodes ~keep =
  let cells, nodes = collect_live_nodes keep t.all_nodes in
  t.all_nodes <- cells;
  nodes

let remember_live_node t ~create_weak_node node =
  t.all_nodes <- create_weak_node node :: t.all_nodes

let live_nodes t ~collect_live_nodes =
  collect_live_node_registry t ~collect_live_nodes ~keep:(fun _ -> true)

let prune_live_nodes t ~collect_live_nodes ~keep =
  ignore (collect_live_node_registry t ~collect_live_nodes ~keep : _ list)

let necessary_ids t ~collect_live_nodes ~root ~reachable_ids =
  ignore (live_nodes t ~collect_live_nodes : _ list);
  reachable_ids ~roots:(List.filter_map root t.observers)

let update_necessity t lane ~collect_live_nodes ~root ~reachable_ids =
  let next = necessary_ids t ~collect_live_nodes ~root ~reachable_ids in
  Eta_signal_graph_core.update_necessary_ids t.core lane next;
  next

type ('id, 'timer) timer_demand = {
  timer_demand_necessary_ids : (Eta_signal_id.signal, unit) Hashtbl.t;
  timer_demand_timers : ('id * 'timer) list;
}

let timer_demand t ~collect_live_nodes ~root ~reachable_ids ~timer =
  let nodes = live_nodes t ~collect_live_nodes in
  {
    timer_demand_necessary_ids =
      reachable_ids ~roots:(List.filter_map root t.observers);
    timer_demand_timers = List.filter_map timer nodes;
  }

let post_commit_necessary_timers t ~collect_live_nodes ~root ~collect_timers =
  ignore (live_nodes t ~collect_live_nodes : _ list);
  collect_timers ~roots:(List.filter_map root t.observers)

let dead_node_count t = List.length t.dead_nodes
let iter_dead_nodes t ~f = List.iter f t.dead_nodes
let map_dead_nodes t ~f = List.map f t.dead_nodes

let remember_dead_node t ~max_count ~id ~equal_id dead_node =
  t.dead_nodes <-
    Eta_signal_debug.remember_latest ~max_count ~id ~equal_id dead_node
      t.dead_nodes
