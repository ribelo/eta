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

let core t = t.core
let stabilization t = t.stabilization
let state t = t.state
let current_scope t = t.current_scope
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

let collect_nodes t collect =
  let cells, nodes = collect t.all_nodes in
  t.all_nodes <- cells;
  nodes

let remember_node t node = t.all_nodes <- node :: t.all_nodes

let prune_nodes t collect =
  ignore (collect_nodes t collect : _ list)

let necessary_ids t ~collect_live_nodes ~root ~reachable_ids =
  ignore (collect_nodes t collect_live_nodes : _ list);
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
  let nodes = collect_nodes t collect_live_nodes in
  {
    timer_demand_necessary_ids =
      reachable_ids ~roots:(List.filter_map root t.observers);
    timer_demand_timers = List.filter_map timer nodes;
  }

let post_commit_necessary_timers t ~collect_live_nodes ~root ~collect_timers =
  ignore (collect_nodes t collect_live_nodes : _ list);
  collect_timers ~roots:(List.filter_map root t.observers)

let dead_nodes t = t.dead_nodes
let dead_node_count t = List.length t.dead_nodes

let remember_dead_node t ~max_count ~id ~equal_id dead_node =
  t.dead_nodes <-
    Eta_signal_debug.remember_latest ~max_count ~id ~equal_id dead_node
      t.dead_nodes
