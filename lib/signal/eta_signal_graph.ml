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
let observers t = t.observers
let add_observer t observer = t.observers <- observer :: t.observers
let update_observers t f = t.observers <- f t.observers

let collect_nodes t collect =
  let cells, nodes = collect t.all_nodes in
  t.all_nodes <- cells;
  nodes

let remember_node t node = t.all_nodes <- node :: t.all_nodes

let prune_nodes t collect =
  ignore (collect_nodes t collect : _ list)

let dead_nodes t = t.dead_nodes
let dead_node_count t = List.length t.dead_nodes

let remember_dead_node t ~max_count ~id ~equal_id dead_node =
  t.dead_nodes <-
    Eta_signal_debug.remember_latest ~max_count ~id ~equal_id dead_node
      t.dead_nodes
