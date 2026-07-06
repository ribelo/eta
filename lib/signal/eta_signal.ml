module Effect = Eta.Effect
module Duration = Eta.Duration
module Queue = Eta.Queue
module Runtime_contract = Eta.Runtime_contract
module Bind = Eta_signal_bind
module Cleanup = Eta_signal_cleanup
module Debug = Eta_signal_debug
module Error = Eta_signal_error
module Graph = Eta_signal_graph
module Id = Eta_signal_id
module Graph_algorithms = Eta_signal_graph_algorithms
module Signal_snapshot = Graph_algorithms.Snapshot
module Observer_core = Eta_signal_observer
module Observer_snapshot = Observer_core.Snapshot
module Observer_lifecycle = Observer_core.Lifecycle
module Scope = Eta_signal_scope
module Stabilization_pass = Eta_signal_stabilization_pass
module Stream_bridge = Eta_signal_stream_bridge
module Test_hooks = Eta_signal_test_hooks
module Timer = Eta_signal_timer
module Timer_policy = Eta_signal_timer_policy
module Transaction = Eta_signal_transaction

module type Observer_error = sig
  type t

  val pp : Format.formatter -> t -> unit
end

module No_observer_error = struct
  type t = |

  let pp _ppf (error : t) = match error with _ -> .
end

module Make (Observer_error : Observer_error) () = struct
  type observer_error = Observer_error.t

  type graph_error = Error.graph_error

  exception Graph_error of graph_error

  type observer_read_error = Error.observer_read_error

  type stabilize_error = observer_error Error.stabilize_error
  type time_error = Error.time_error
  type stream_error = Error.stream_error

  type 'a update = 'a Observer_core.Update.t =
    | Initialized of 'a
    | Changed of {
        old_value : 'a;
        new_value : 'a;
      }

  type stats = {
    pure_snapshot_commit_count : int;
    callback_delivery_count : int;
    total_node_count : int;
    active_observer_count : int;
    invalid_observer_count : int;
    necessary_node_count : int;
    dead_node_count : int;
    live_dirty_node_count : int;
    recompute_count : int;
    dynamic_scope_invalidations : int;
    nodes_became_necessary : int;
    nodes_became_unnecessary : int;
    stream_bridge_drop_count : int;
    lane_waiter_count : int;
    lane_cancelled_waiter_count : int;
  }

  type dot_scope = [ `Necessary | `All_valid | `All_including_invalid ]

  type dot_options = {
    dot_scope : dot_scope;
    dot_observers : bool;
    dot_timers : bool;
    dot_state : bool;
    dot_dynamic_scopes : bool;
  }

  let default_dot_options =
    {
      dot_scope = `Necessary;
      dot_observers = false;
      dot_timers = false;
      dot_state = false;
      dot_dynamic_scopes = false;
    }

  let pp_graph_error = Error.pp_graph_error
  let pp_observer_read_error = Error.pp_observer_read_error
  let pp_stabilize_error ppf err =
    Error.pp_stabilize_error Observer_error.pp ppf err

  let pp_time_error = Error.pp_time_error
  let pp_stream_error = Error.pp_stream_error

  let default_equal a b = a == b

  let saturating_succ value =
    if value = max_int then max_int else value + 1

  let counter_overflow name = raise (Graph_error (`Counter_overflow name))

  let checked_succ name value =
    if value = max_int then counter_overflow name else value + 1

  type signal_id = Id.signal
  type scope_id = Id.scope
  type var_id = Id.var
  type observer_id = Id.observer

  let signal_id_int = Id.signal_int
  let scope_id_int = Id.scope_int
  let var_id_int = Id.var_int
  let observer_id_int = Id.observer_int

  let signal_id_label = Id.signal_label
  let dead_signal_id_label = Id.dead_signal_label
  let scope_id_label = Id.scope_label
  let var_id_label = Id.var_label
  let observer_id_label = Id.observer_label
  let compare_observer_id = Id.compare_observer

  type weak_packed_signal = Graph_algorithms.Weak_cell.t

  type timer_catch_up_policy = Timer_policy.catch_up_policy =
    | Catch_up_every_cadence
    | Catch_up_once_per_wake
    | Catch_up_coalesced

  type scope = (scope_id, packed_signal, packed_signal) Scope.t

  and packed_signal = P : 'a signal -> packed_signal

  and 'a signal = {
    id : signal_id;
    equal : 'a -> 'a -> bool;
    mutable kind : 'a kind;
    snapshot : (signal_id, 'a) Signal_snapshot.t Transaction.staged;
    mutable dirty : bool;
    mutable dependencies : packed_signal list;
    mutable dependents : packed_signal list;
    mutable computing : bool;
    mutable seen_generation : int;
    mutable changed_seen : bool;
    mutable computed_generation : int;
    scope : scope option;
    mutable valid : bool;
    mutable timer : timer_node option;
  }

  and _ kind =
    | Const : 'a -> 'a kind
    | Var : 'a var -> 'a kind
    | Map : 'a signal * ('a -> 'b) -> 'b kind
    | Map2 : 'a signal * 'b signal * ('a -> 'b -> 'c) -> 'c kind
    | Map3 :
        'a signal * 'b signal * 'c signal * ('a -> 'b -> 'c -> 'd)
        -> 'd kind
    | Map4 :
        'a signal
        * 'b signal
        * 'c signal
        * 'd signal
        * ('a -> 'b -> 'c -> 'd -> 'e)
        -> 'e kind
    | Map5 :
        'a signal
        * 'b signal
        * 'c signal
        * 'd signal
        * 'e signal
        * ('a -> 'b -> 'c -> 'd -> 'e -> 'f)
        -> 'f kind
    | Map6 :
        'a signal
        * 'b signal
        * 'c signal
        * 'd signal
        * 'e signal
        * 'f signal
        * ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g)
        -> 'g kind
    | Map7 :
        'a signal
        * 'b signal
        * 'c signal
        * 'd signal
        * 'e signal
        * 'f signal
        * 'g signal
        * ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g -> 'h)
        -> 'h kind
    | Map8 :
        'a signal
        * 'b signal
        * 'c signal
        * 'd signal
        * 'e signal
        * 'f signal
        * 'g signal
        * 'h signal
        * ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g -> 'h -> 'i)
        -> 'i kind
    | Map9 :
        'a signal
        * 'b signal
        * 'c signal
        * 'd signal
        * 'e signal
        * 'f signal
        * 'g signal
        * 'h signal
        * 'i signal
        * ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g -> 'h -> 'i -> 'j)
        -> 'j kind
    | All : 'a signal list -> 'a list kind
    | Bind : ('a, 'b) bind -> 'b kind

  and ('a, 'b) bind = {
    source : 'a signal;
    selector : 'a -> 'b signal;
    mutable owner : 'b signal option;
    snapshot : ('a, 'b signal, scope) Bind.snapshot Transaction.staged;
  }

  and packed_bind = B : ('a, 'b) bind -> packed_bind

  and 'a var = {
    var_id : var_id;
    var_equal : 'a -> 'a -> bool;
    source_value : 'a Transaction.staged;
    graph_value : 'a Transaction.staged;
    mutable queued : bool;
    mutable updating : bool;
    mutable watchers : weak_packed_signal list;
  }

  and packed_var = V : 'a var -> packed_var

  and observer_after_ack_action = unit -> unit

  and 'a observer_delivery_state =
    ('a, observer_after_ack_action) Observer_core.Delivery.t

  and 'a observer_live_state = {
    observer_snapshot :
      ('a, observer_after_ack_action) Observer_snapshot.t
      Transaction.staged;
    mutable obs_on_finish : (Observer_lifecycle.finish_reason -> unit) list;
  }

  and 'a observer_state =
    ('a observer_live_state, 'a Observer_core.Value.t) Observer_lifecycle.t

  and 'a observer = {
    obs_id : observer_id;
    obs_signal : 'a signal;
    obs_equal : 'a -> 'a -> bool;
    obs_callback :
      Observer_core.Delivery.token ->
      'a update ->
      (unit, observer_error) Effect.t;
    mutable obs_state : 'a observer_state;
  }

  and packed_observer = O : 'a observer -> packed_observer

  and timer_refresh_operation =
    | Refresh_operation : 'a var * 'a Timer_policy.refresh_spec -> timer_refresh_operation

  and timer_transition =
    | Set_source : 'a var * 'a -> timer_transition
    | Advance_due of int
    | Finish of Timer_policy.finish_plan

  and timer_node = timer_refresh_operation Timer.node

  and timer_update = {
    timer_catch_up_policy : timer_catch_up_policy;
    timer_update : 'err. timer_node -> int -> missed:int -> (unit, 'err) Effect.t;
  }

  and dead_signal = {
    dead_id : signal_id;
    dead_kind : string;
    dead_initialized : bool;
    dead_dirty : bool;
    dead_computing : bool;
    dead_dependency_ids : signal_id list;
    dead_dependency_count : int;
    dead_dependent_count : int;
    dead_scope_id : scope_id option;
    dead_scope_owner : signal_id option;
    dead_scope_parent : scope_id option;
    dead_scope_valid : bool option;
    dead_timer : Timer_policy.debug_snapshot option;
  }

  and 'a source_timer_update = {
    source_timer_update :
      'err. timer_node -> int -> missed:int -> 'a var -> (unit, 'err) Effect.t;
  }

  open Observer_core.Delivery

  let packed_signal_id (P signal) = signal.id
  let scope_owner_id scope = packed_signal_id (Scope.owner scope)

  module Scope_validation = Scope.Make_validation (struct
    type node_id = signal_id
    type nonrec scope_id = scope_id
    type owner = packed_signal
    type node = packed_signal

    let node_id (P signal) = signal.id
    let valid (P signal) = signal.valid
    let scope (P signal) = signal.scope

    let children (P signal) =
      match signal.kind with
      | Bind _ -> []
      | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _ | Map6 _
      | Map7 _ | Map8 _ | Map9 _ | All _ ->
          signal.dependencies
  end)

  module Graph_edge_node = struct
    type nonrec packed = packed_signal
    type t = Packed : 'a signal -> t

    let pack (Packed signal) = P signal
  end

  let graph_edge_node signal = Graph_edge_node.Packed signal

  let graph_node_identity =
    Graph.node_identity ~id:(fun (P signal) -> signal.id)
      ~equal_id:(fun left right -> signal_id_int left = signal_id_int right)

  let edge_ops =
    Graph.edge_ops ~identity:graph_node_identity
      ~dependencies:(fun (P signal) -> signal.dependencies)
      ~set_dependencies:(fun (P signal) dependencies ->
        signal.dependencies <- dependencies)
      ~dependents:(fun (P signal) -> signal.dependents)
      ~set_dependents:(fun (P signal) dependents ->
        signal.dependents <- dependents)

  module Initial_edges = Graph_algorithms.Make_edges (struct
    type id = signal_id
    type nonrec packed = packed_signal
    type nonrec t = packed_signal

    let pack packed = packed
    let unpack packed = packed
    let id = packed_signal_id
    let equal_id left right = signal_id_int left = signal_id_int right
    let dependencies (P signal) = signal.dependencies
    let set_dependencies (P signal) dependencies =
      signal.dependencies <- dependencies

    let dependents (P signal) = signal.dependents
    let set_dependents (P signal) dependents =
      signal.dependents <- dependents
  end)

  let dirty_ops =
    Graph.dirty_ops ~identity:graph_node_identity
      ~dirty:(fun (P signal) -> signal.dirty)
      ~set_dirty:(fun (P signal) dirty -> signal.dirty <- dirty)

  let compute_ops =
    Graph.compute_ops ~node:(fun (P signal) -> graph_edge_node signal)
      ~pack:Graph_edge_node.pack
      ~seen_generation:(fun (Graph_edge_node.Packed signal) ->
        signal.seen_generation)
      ~set_seen_generation:(fun (Graph_edge_node.Packed signal) generation ->
        signal.seen_generation <- generation)
      ~changed_seen:(fun (Graph_edge_node.Packed signal) ->
        signal.changed_seen)
      ~set_changed_seen:(fun (Graph_edge_node.Packed signal) changed ->
        signal.changed_seen <- changed)
      ~computing:(fun (Graph_edge_node.Packed signal) -> signal.computing)
      ~set_computing:(fun (Graph_edge_node.Packed signal) computing ->
        signal.computing <- computing)
      ~computed_generation:(fun (Graph_edge_node.Packed signal) ->
        signal.computed_generation)
      ~set_computed_generation:(fun (Graph_edge_node.Packed signal) generation ->
        signal.computed_generation <- generation)

  let publish_initial_current staged value =
    Transaction.publish_current Transaction.initialize_current staged value

  let publish_source_current staged value =
    Transaction.publish_current Transaction.source_publication staged value

  let publish_observer_current staged value =
    Transaction.publish_current Transaction.observer_publication staged value

  let publish_timer_current staged value =
    Transaction.publish_current Transaction.timer_lifecycle staged value

  module Private_test_hooks = struct
    type hook = Test_hooks.hook =
      | After_observer_delivery_claim
      | After_observer_activation_before_return
      | After_graph_lane_acquired

    type action = Test_hooks.action = {
      run : 'err. unit -> (unit, 'err) Effect.t;
    }

    let state = Test_hooks.create ()
    let with_hook hook action f = Test_hooks.with_hook state hook action f
    let clear () = Test_hooks.clear state
    let run hook = Test_hooks.run state hook
  end

  type disposal_hook = Cleanup.hook

  type timer_refresh_context =
    (Runtime_contract.t, packed_signal * bool) Timer_policy.refresh_context

  type graph =
    ( packed_var,
      packed_bind,
      packed_signal,
      disposal_hook,
      timer_node,
      timer_refresh_context,
      packed_observer,
      weak_packed_signal,
      dead_signal,
      (scope_id, packed_signal, packed_signal) Scope.context,
      Stream_bridge.metrics )
    Graph.t

  let graph =
    Graph.create ~create_scope_context:Scope.create_context
      ~create_stream_bridge_metrics:Stream_bridge.create_metrics ()

  let graph_stream_bridge_metrics () = Graph.stream_bridge_metrics graph

  let scope_ops =
    Graph.scope_ops ~current:Scope.current
      ~require_valid_current:Scope.require_valid_current
      ~with_current:Scope.with_current

  let pack_weak_signal signal = P signal
  let weak_packed_signal (P signal) = Graph_algorithms.Weak_cell.create signal
  let weak_packed_signal_value cell =
    Graph_algorithms.Weak_cell.value ~pack:pack_weak_signal cell

  let collect_live_weak_signals keep cells =
    Graph_algorithms.Weak_cell.collect ~pack:pack_weak_signal ~keep cells

  let live_signal_registry =
    Graph.live_node_registry ~collect_live_nodes:collect_live_weak_signals

  let all_nodes_unlocked lane =
    Graph.live_nodes graph lane live_signal_registry

  let prune_all_nodes_unlocked lane =
    Graph.prune_live_nodes graph lane live_signal_registry
      ~keep:(fun _ -> true)

  let children_with_scope_owner signal children =
    Scope.children_with_scope_owner
      ~owner_valid:(fun (P owner) -> owner.valid)
      ~owner_node:(fun owner -> owner)
      signal.scope children

  let reachable_ops =
    Graph.reachable_ops ~id:(fun (P signal) -> signal.id)
      ~valid:(fun (P signal) -> signal.valid)
      ~children:(fun (P signal) ->
        children_with_scope_owner signal signal.dependencies)

  let source_watchers_unlocked source =
    let cells, watchers =
      collect_live_weak_signals (fun (P signal) -> signal.valid) source.watchers
    in
    source.watchers <- cells;
    watchers

  let kind_name : type a. a kind -> string = function
    | Const _ -> "const"
    | Var _ -> "var"
    | Map _ -> "map"
    | Map2 _ -> "map2"
    | Map3 _ -> "map3"
    | Map4 _ -> "map4"
    | Map5 _ -> "map5"
    | Map6 _ -> "map6"
    | Map7 _ -> "map7"
    | Map8 _ -> "map8"
    | Map9 _ -> "map9"
    | All _ -> "all"
    | Bind _ -> "bind"

  let graph_context_error_message = Graph.context_error_message

  let ensure_graph_context () = Graph.ensure_context graph

  let graph_lane_depth_local : int Runtime_contract.local =
    Runtime_contract.create_local ()

  type graph_lane = Graph.lane_access

  type event =
    (graph_lane, (unit, observer_error) Effect.t, stabilize_error)
    Observer_core.Delivery_event.t

  let with_graph_lane_access f =
    Graph.with_lane_access graph
      ~leaf_name:"Eta_signal.with_graph_lane_sync"
      ~depth_local:graph_lane_depth_local
      ~hooks:
        (Graph.lane_hooks
           ~note_waiter_enqueued:ignore
           ~note_waiter_compaction:ignore)
      ~after_acquired:(fun () ->
        Private_test_hooks.run After_graph_lane_acquired)
      f

  let with_graph_lane_sync f =
    with_graph_lane_access (fun _lane -> f ())

  (* Synchronous constructors mutate graph indexes without entering the graph
     lane. Keep this path same-domain, non-effectful, and callback-free;
     effectful public operations must use [with_graph_lane_sync]. *)
  let graph_result_or_raise = function
    | Ok value -> value
    | Error err -> raise (Graph_error err)

  let next_var_id () =
    ensure_graph_context ();
    graph_result_or_raise (Graph.next_var_id graph)

  let next_observer_id () =
    ensure_graph_context ();
    graph_result_or_raise (Graph.next_observer_id graph)

  let new_scope owner =
    Scope.create
      ~id:(graph_result_or_raise (Graph.next_scope_id graph))
      ~owner:(P owner) ~parent:owner.scope

  let current_generation lane = Graph.generation graph lane

  let detach_dependency lane parent child =
    Graph.detach_dependency graph lane edge_ops ~parent:(P parent)
      ~child:(P child)

  let attach_dependency lane parent child =
    Graph.attach_dependency graph lane edge_ops ~parent:(P parent)
      ~child:(P child)

  let attach_initial_packed_dependency parent child =
    Initial_edges.attach_dependency ~parent:(P parent) ~child

  let mark_self_dirty lane packed =
    Graph.mark_dirty graph lane dirty_ops packed

  let mark_timer_refresh_dirty lane staging packed =
    Graph.mark_timer_refresh_dirty graph lane staging
      ~mark:(fun () -> Graph.mark_dirty graph lane dirty_ops packed)
      ~record:(fun context ->
        Timer_policy.set_refresh_dirty_items context
          (Graph.mark_dirty_recording_previous graph lane dirty_ops
             (Timer_policy.refresh_dirty_items context)
             packed))

  let remove_var_watcher source signal =
    source.watchers <-
      List.filter
        (fun cell ->
          match weak_packed_signal_value cell with
          | None -> false
          | Some (P candidate) -> candidate.valid && candidate.id <> signal.id)
        source.watchers

  let stage_var_graph_value (type a) lane staging (var : a var) value =
    Graph.stage_cell graph lane staging var.graph_value value

  let stage_var_source_value (type a) lane staging (var : a var) value =
    Graph.stage_cell graph lane staging var.source_value value

  let effective_var_value (type a) (var : a var) =
    Graph.read_effective graph var.graph_value

  let remember_computed lane staging (P signal) =
    Graph.remember_computed graph lane staging compute_ops (P signal)

  let signal_current_snapshot signal =
    Transaction.current signal.snapshot

  let signal_effective_snapshot signal =
    Graph.read_effective graph signal.snapshot

  let effective_signal_version signal =
    Signal_snapshot.version (signal_effective_snapshot signal)

  let version_ops =
    Graph.version_ops ~identity:graph_node_identity
      ~version:(fun (P signal) -> effective_signal_version signal)

  let update_signal_staging lane staging signal f =
    Graph.update_cell graph lane staging signal.snapshot f

  let signal_staged_in_active_transaction lane staging signal =
    Graph.staged_in_active_transaction graph lane staging signal.snapshot

  let stage_signal lane staging signal value =
    update_signal_staging lane staging signal (fun snapshot ->
        let current = signal_current_snapshot signal in
        Signal_snapshot.publish
          ~advance_version:(checked_succ "signal version")
          ~current snapshot value)

  let dependency_versions lane dependencies =
    Graph.version_snapshot graph lane version_ops dependencies

  let dependencies_changed lane signal dependencies =
    Graph.versions_changed graph lane version_ops
      ~current:
        (Signal_snapshot.dependency_versions
           (signal_current_snapshot signal))
      dependencies

  let stage_dependency_versions lane staging signal dependencies =
    update_signal_staging lane staging signal (fun snapshot ->
        Signal_snapshot.with_dependency_versions snapshot
          (dependency_versions lane dependencies))

  let effective_signal_value signal =
    match Signal_snapshot.value (signal_effective_snapshot signal) with
    | Some value -> value
    | None -> raise (Graph_error `Invalid_scope)

  let observer_active_live_state observer =
    Observer_lifecycle.active_live observer.obs_state

  let observer_current_snapshot live =
    Transaction.current live.observer_snapshot

  let observer_effective_snapshot live =
    Graph.read_effective graph live.observer_snapshot

  let set_observer_current live snapshot =
    publish_observer_current live.observer_snapshot snapshot

  let observer_active (O observer) =
    Observer_lifecycle.active observer.obs_state

  let observer_demands_signal (O observer) =
    Observer_lifecycle.demands observer.obs_state

  let observer_roots selected observers =
    List.filter_map
      (fun (O observer as packed) ->
        if selected packed then Some (P observer.obs_signal) else None)
      observers

  let observer_demand_roots =
    Graph.demand_roots ~demand:observer_demands_signal
      ~root:(fun (O observer) -> P observer.obs_signal)

  let graph_reachable_plan () =
    Graph.reachable_plan ~ops:reachable_ops
      ~registry:live_signal_registry ~roots:observer_demand_roots

  let observer_active_roots observers =
    observer_roots observer_active observers

  let observer_identity =
    Graph.observer_identity ~same:(fun (O candidate) (O target) ->
        candidate.obs_id = target.obs_id)

  let remove_observer lane observer =
    Graph.remove_observer graph lane observer_identity (O observer)

  let observer_finish_hooks live reason =
    List.map (fun hook () -> hook reason) live.obs_on_finish

  let observer_activation_port () =
    Observer_core.activation_port
      ~state:(fun observer -> observer.obs_state)
      ~set_state:(fun observer state -> observer.obs_state <- state)

  let observer_lifecycle_port lane =
    Observer_core.lifecycle_port
      ~state:(fun observer -> observer.obs_state)
      ~set_state:(fun observer state -> observer.obs_state <- state)
      ~value:(fun live ->
        Observer_snapshot.value (observer_current_snapshot live))
      ~finish_hooks:observer_finish_hooks ~remove:(remove_observer lane)

  let run_after_ack_actions_unlocked actions =
    List.iter (fun action -> action ()) actions

  let observer_delivery_port () =
    Observer_core.delivery_port
      ~live:(fun (_lane : graph_lane) observer ->
        observer_active_live_state observer)
      ~snapshot:(fun (_lane : graph_lane) live ->
        observer_current_snapshot live)
      ~set_snapshot:(fun (_lane : graph_lane) live snapshot ->
        set_observer_current live snapshot)
      ~run_after_ack:(fun (_lane : graph_lane) actions ->
        run_after_ack_actions_unlocked actions)

  let dispose_observer_unlocked lane observer =
    Observer_core.dispose_observer (observer_lifecycle_port lane) observer

  let invalidate_observer_unlocked lane observer =
    Observer_core.invalidate_observer (observer_lifecycle_port lane) observer

  let dispose_signal_observers lane signal =
    Graph.collect_observer_cleanup_hooks graph lane
      (Graph.observer_cleanup
         ~selected:(fun (O observer) -> observer.obs_signal.id = signal.id)
         ~cleanup:(fun (O observer) ->
           invalidate_observer_unlocked lane observer))

  let validate_dependency (P signal) =
    if not signal.valid then raise (Graph_error `Invalid_scope)

  let timer_state_generation = Timer_policy.state_generation

  let timer_current_snapshot timer =
    Transaction.current (Timer.snapshot_cell timer)

  let timer_effective_snapshot timer =
    Graph.read_effective graph (Timer.snapshot_cell timer)

  let set_timer_current_snapshot timer snapshot =
    publish_timer_current (Timer.snapshot_cell timer) snapshot

  let set_timer_current_state timer timer_state =
    let snapshot = timer_current_snapshot timer in
    set_timer_current_snapshot timer
      (Timer_policy.snapshot_with_state snapshot timer_state)

  let update_timer_staging lane staging timer f =
    let snapshot_cell = Timer.snapshot_cell timer in
    Graph.update_cell graph lane staging snapshot_cell f

  let timer_current_state timer =
    Timer_policy.snapshot_state (timer_current_snapshot timer)

  let timer_generation timer =
    timer_state_generation (timer_current_state timer)

  let timer_state_label = Timer_policy.state_label

  let timer_has_staged_refresh timer =
    Graph.timer_has_staged_refresh graph timer
      ~refresh_token:Timer_policy.refresh_token
      ~staged_token:Timer.staged_refresh_token

  let timer_effective_state timer =
    if timer_has_staged_refresh timer then
      Timer_policy.snapshot_state (timer_effective_snapshot timer)
    else timer_current_state timer

  let timer_state_port =
    Timer.state_port ~effective:timer_effective_state
      ~current:timer_current_state ~set_current:set_timer_current_state

  let timer_needs_start timer =
    Timer_policy.needs_start ~effective_state:(timer_effective_state timer)
      ~current_state:(timer_current_state timer)

  let timer_runtime_mismatch _runtime_contract _timer =
    (`Runtime_mismatch : graph_error)

  let ensure_timer_runtime timer runtime_contract =
    match
      Timer.validate_runtime ~runtime_mismatch:timer_runtime_mismatch
        runtime_contract timer
    with
    | Ok () -> ()
    | Error err -> raise (Graph_error err)

  let timer_running_generation timer =
    Timer_policy.state_running_generation (timer_effective_state timer)

  let timer_has_cancel timer =
    Timer_policy.state_has_cancel (timer_effective_state timer)

  let add_int_capped = Timer_policy.add_int_capped

  let timer_set_next_due_state = Timer_policy.state_set_next_due

  let remember_timer_refresh_timer lane staging timer =
    Graph.remember_timer_refresh_timer graph lane staging timer
      ~refresh_token:Timer_policy.refresh_token
      ~staged_token:Timer.staged_refresh_token
      ~set_staged_token:Timer.set_staged_refresh_token
      ~stage_refresh_token:(fun timer token ->
        update_timer_staging lane staging timer (fun snapshot ->
            Timer_policy.snapshot_with_on_demand_refresh_token snapshot token))

  let stage_timer_state_unlocked lane staging timer state =
    remember_timer_refresh_timer lane staging timer;
    update_timer_staging lane staging timer (fun snapshot ->
        Timer_policy.snapshot_with_state snapshot state)

  let timer_mark_unneeded_unlocked ?(cancel_running = true) timer =
    Timer.mark_node_unneeded
      ~advance_generation:(checked_succ "timer generation")
      ~cancel_running timer_state_port timer

  let node_lifecycle ?equal ~dirty kind =
    Graph.node_lifecycle ~validate_dependency
      ~create:(fun ~id ~scope ->
        {
          id;
          equal = Option.value equal ~default:default_equal;
          kind;
          snapshot = Transaction.create_staged Signal_snapshot.empty;
          dirty;
          dependencies = [];
          dependents = [];
          computing = false;
          seen_generation = -1;
          changed_seen = false;
          computed_generation = -1;
          scope;
          valid = true;
          timer = None;
        })
      ~attach_dependency:(fun ~parent ~child ->
        attach_initial_packed_dependency parent child)
      ~add_to_scope:(fun scope signal -> Scope.add_node scope (P signal))
      ~pack:(fun signal -> P signal)
      ~create_weak:weak_packed_signal

  let new_signal ?(dirty = true) ?equal kind dependencies =
    graph_result_or_raise
      (Graph.create_live_node graph scope_ops
         (node_lifecycle ?equal ~dirty kind)
         ~dependencies)

  let new_const ?equal value =
    let signal = new_signal ?equal ~dirty:false (Const value) [] in
    publish_initial_current signal.snapshot
      (Signal_snapshot.initialized value);
    signal

  let prune_invalid_nodes_unlocked lane =
    Graph.prune_live_nodes graph lane live_signal_registry
      ~keep:(fun (P signal) -> signal.valid)

  let timer_debug_snapshot timer =
    let snapshot = Timer_policy.debug_snapshot (timer_effective_state timer) in
    Timer_policy.debug_snapshot_with_generation snapshot
      (timer_generation timer)

  let timer_tombstone timer = timer_debug_snapshot timer

  let signal_tombstone (P signal) =
    let dead_scope_id, dead_scope_owner, dead_scope_parent, dead_scope_valid =
      match signal.scope with
      | None -> (None, None, None, None)
      | Some scope ->
          ( Some (Scope.id scope),
            Some (scope_owner_id scope),
            Option.map (fun parent -> Scope.id parent) (Scope.parent scope),
            Some (Scope.valid scope) )
    in
    let snapshot = signal_current_snapshot signal in
    {
      dead_id = signal.id;
      dead_kind = kind_name signal.kind;
      dead_initialized = Signal_snapshot.is_initialized snapshot;
      dead_dirty = signal.dirty;
      dead_computing = signal.computing;
      dead_dependency_ids =
        List.map (fun (P dependency) -> dependency.id) signal.dependencies;
      dead_dependency_count = List.length signal.dependencies;
      dead_dependent_count = List.length signal.dependents;
      dead_scope_id;
      dead_scope_owner;
      dead_scope_parent;
      dead_scope_valid;
      dead_timer = Option.map timer_tombstone signal.timer;
    }

  let node_invalidation lane =
    Graph.node_invalidation
      ~valid:(fun (P signal) -> signal.valid)
      ~set_invalid:(fun (P signal) -> signal.valid <- false)
      ~timer_hooks:(fun (P signal) ->
        match signal.timer with
        | None -> []
        | Some timer -> timer_mark_unneeded_unlocked timer)
      ~tombstone:signal_tombstone
      ~tombstone_id:(fun tombstone -> tombstone.dead_id)
      ~observer_hooks:(fun (P signal) -> dispose_signal_observers lane signal)
      ~kind_hooks:(fun ~invalidate_scope (P signal) ->
        match signal.kind with
        | Var source ->
            remove_var_watcher source signal;
            []
        | Bind bind -> (
            match Bind.inner_scope (Transaction.current bind.snapshot) with
            | None -> []
            | Some scope -> invalidate_scope ~prune:false scope)
        | Const _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _ | Map6 _
        | Map7 _ | Map8 _ | Map9 _ | All _ ->
            [])

  let rec invalidate_scope lane ?(prune = true) scope =
    match Scope.invalidate scope with
    | None -> []
    | Some nodes ->
        Graph.bump_counter graph lane Graph.Dynamic_scope_invalidations;
        let hooks = List.concat_map (invalidate_node lane) nodes in
        if prune then prune_invalid_nodes_unlocked lane;
        hooks

  and invalidate_node lane packed =
    Graph.invalidate_live_node graph lane edge_ops (node_invalidation lane)
      ~invalidate_scope:(invalidate_scope lane) packed

  let make_bind ?equal source selector =
    let bind =
      {
        source;
        selector;
        owner = None;
        snapshot = Transaction.create_staged Bind.empty;
      }
    in
    let signal = new_signal ?equal (Bind bind) [ P source ] in
    bind.owner <- Some signal;
    signal

  let current_or_raise signal =
    match Signal_snapshot.value (signal_current_snapshot signal) with
    | Some value -> value
    | None -> raise (Graph_error `Invalid_scope)

  let signal_commit (P signal) =
    Graph.staged_signal_commit ~valid:signal.valid ~cell:signal.snapshot
      ~commit:(fun () -> signal.dirty <- false)

  let stage_bind_switch (type a b) lane staging (bind : (a, b) bind)
      source_value inner scope =
    Graph.stage_bind_switch graph lane staging (B bind) bind.snapshot
      ~source_value ~inner ~scope

  let bind_current_snapshot (type a b) (bind : (a, b) bind) :
      (a, b signal, scope) Bind.snapshot =
    Transaction.current bind.snapshot

  module Scope_invalidation = Scope.Make_invalidation (struct
    type nonrec node_id = signal_id
    type nonrec scope_id = scope_id
    type nonrec owner = packed_signal
    type nonrec node = packed_signal

    let node_id (P signal) = signal.id
    let equal_node_id left right = signal_id_int left = signal_id_int right
    let valid (P signal) = signal.valid
    let dependents (P signal) = signal.dependents

    let nested_scope (P signal) =
      match signal.kind with
      | Bind bind -> Bind.inner_scope (bind_current_snapshot bind)
      | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _
      | Map6 _ | Map7 _ | Map8 _ | Map9 _ | All _ ->
          None
  end)

  let bind_effective_snapshot (type a b) (bind : (a, b) bind) :
      (a, b signal, scope) Bind.snapshot =
    Graph.read_effective graph bind.snapshot

  let bind_staged_snapshot (type a b) lane staging (bind : (a, b) bind) :
      (a, b signal, scope) Bind.snapshot option =
    Graph.staged_value graph lane staging bind.snapshot

  let bind_staged_switch (type a b) lane staging (bind : (a, b) bind) :
      (a, b signal, scope, b signal) Bind.staged_switch =
    Bind.staged_switch ~owner:bind.owner
      ~current:(bind_current_snapshot bind)
      ~staged:(bind_staged_snapshot lane staging bind)

  let packed_bind_staged_switch lane staging (B bind) =
    Bind.pack_staged_switch
      (Bind.staged_switch
         ~owner:(Option.map (fun owner -> P owner) bind.owner)
         ~current:(bind_current_snapshot bind)
         ~staged:(bind_staged_snapshot lane staging bind))

  let bind_switch_lifecycle lane =
    Bind.staged_switch_lifecycle
      ~detach_old_inner:(detach_dependency lane)
      ~invalidate_scope:(invalidate_scope lane)
      ~attach_new_inner:(attach_dependency lane)

  let collect_scope_invalidations_into ?exclude_signal_id seen collected scope =
    Scope_invalidation.collect ?exclude_node_id:exclude_signal_id seen
      collected scope

  let preflight_timer_invalidation timer =
    Timer.preflight_stop ~advance_generation:(checked_succ "timer generation")
      timer_state_port timer

  let preflight_timer_start timer =
    Timer.preflight_start ~advance_generation:(checked_succ "timer generation")
      timer_state_port timer

  type staged_bind_invalidation_view = {
    invalidated_ids : (signal_id, unit) Hashtbl.t;
    invalidated_nodes : packed_signal list;
  }

  let staged_bind_invalidates view (P signal) =
    Hashtbl.mem view.invalidated_ids signal.id

  let preflight_signal_commit lane staging invalidations (P signal) =
    if
      signal.valid
      && not (staged_bind_invalidates invalidations (P signal))
      && signal_staged_in_active_transaction lane staging signal
    then
      let current = signal_current_snapshot signal in
      let staged = signal_effective_snapshot signal in
      Signal_snapshot.preflight_commit_version
        ~advance_version:(checked_succ "signal version")
        ~current ~staged

  let collect_staged_bind_invalidations lane staging =
    let invalidated_ids = Hashtbl.create 16 in
    let invalidated_nodes = ref [] in
    let plan =
      Graph.staged_bind_invalidation_plan
        ~init:(invalidated_ids, invalidated_nodes)
        ~staged_switch:(packed_bind_staged_switch lane staging)
        ~collect_old_scope:(fun (seen, collected) ~owner scope ->
          let P owner_signal = owner in
          collect_scope_invalidations_into ~exclude_signal_id:owner_signal.id
            seen collected scope;
          (seen, collected))
    in
    match
      Graph.collect_staged_bind_switch_invalidations graph lane staging plan
    with
    | Ok (invalidated_ids, invalidated_nodes) ->
        { invalidated_ids; invalidated_nodes = !invalidated_nodes }
    | Error err -> raise (Graph_error err)

  let signal_timer (P signal) =
    Option.map (fun timer -> (signal.id, timer)) signal.timer

  let collect_post_commit_necessary_timers lane invalidations =
    let reachable_ops =
      Graph.reachable_ops ~id:(fun (P signal) -> signal.id)
        ~valid:(fun (P signal) ->
          signal.valid
          && not (staged_bind_invalidates invalidations (P signal)))
        ~children:(fun (P signal) ->
          let signal_children =
            match signal.kind with
            | Bind bind ->
                Bind.dependencies ~source:(P bind.source)
                  ~inner_dependency:(fun inner -> P inner)
                  (bind_effective_snapshot bind)
            | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _
            | Map6 _ | Map7 _ | Map8 _ | Map9 _ | All _ ->
                signal.dependencies
          in
          children_with_scope_owner signal signal_children)
    in
    let plan =
      Graph.reachable_plan ~ops:reachable_ops
        ~registry:live_signal_registry
        ~roots:observer_demand_roots
    in
    Graph.post_commit_necessary_timers graph lane
      (Graph.timer_demand_source ~reachable:plan ~timer:signal_timer)

  let preflight_post_commit_timer_starts lane invalidations =
    collect_post_commit_necessary_timers lane invalidations
    |> Hashtbl.iter (fun _ timer -> preflight_timer_start timer)

  let preflight_commit_staging lane staging =
    Graph.staged_preflight ~preflight:(fun () ->
        let invalidations = collect_staged_bind_invalidations lane staging in
        List.iter
          (fun (P signal) ->
            Option.iter preflight_timer_invalidation signal.timer)
          invalidations.invalidated_nodes;
        Graph.iter_computed graph lane staging
          ~f:(preflight_signal_commit lane staging invalidations);
        preflight_post_commit_timer_starts lane invalidations)

  let remember_pure_disposal_hooks lane staging hooks =
    Graph.remember_pure_disposal_hooks graph lane staging hooks

  let remember_timer_refresh_disposal_hooks lane staging hooks =
    Graph.remember_timer_refresh_disposal_hooks graph lane staging hooks

  let queue_var_unlocked (type a) lane (source : a var) =
    if not source.queued then (
      source.queued <- true;
      Graph.enqueue_pending graph lane (V source))

  let set_var_source_unlocked (type a) lane (source : a var) value =
    publish_source_current source.source_value value;
    queue_var_unlocked lane source

  let stage_timer_source_value (type a) lane staging (source : a var) value =
    let graph_value = effective_var_value source in
    stage_var_source_value lane staging source value;
    if not (source.var_equal graph_value value) then (
      stage_var_graph_value lane staging source value;
      List.iter
        (mark_timer_refresh_dirty lane staging)
        (source_watchers_unlocked source))

  let timer_finish_unlocked timer =
    Timer.finish_node ~advance_generation:(checked_succ "timer generation")
      timer_state_port timer

  let stage_timer_transition lane staging timer = function
    | Set_source (source, value) ->
        stage_timer_source_value lane staging source value
    | Advance_due next_due_ms ->
        stage_timer_state_unlocked lane staging timer
          (timer_set_next_due_state (timer_effective_state timer)
             (Some next_due_ms))
    | Finish plan ->
        Timer_policy.finish_plan_result plan ~plan:(fun ~state ~cancel_hooks ->
            stage_timer_state_unlocked lane staging timer state;
            remember_timer_refresh_disposal_hooks lane staging cancel_hooks)

  let timer_refresh_action source = function
    | Timer_policy.Refresh_set value -> Set_source (source, value)
    | Timer_policy.Refresh_advance_due next_due_ms -> Advance_due next_due_ms
    | Timer_policy.Refresh_finish plan -> Finish plan

  let timer_refresh_plan timer now_ms (Refresh_operation (source, spec)) =
    Timer_policy.refresh_actions_for_spec
      ~advance_generation:(checked_succ "timer generation")
      ~state:(timer_effective_state timer)
      ~current_value:(effective_var_value source) ~now_ms spec
    |> List.map (timer_refresh_action source)

  let stage_timer_refresh_operation lane staging timer now_ms operation =
    List.iter
      (stage_timer_transition lane staging timer)
      (timer_refresh_plan timer now_ms operation)

  let clear_timer_refresh_timer_staging timer =
    Timer.set_staged_refresh_token timer (-1)

  let timer_refresh_commit timer =
    Graph.staged_timer_commit ~commit:(fun () ->
        clear_timer_refresh_timer_staging timer)

  let staging_reset_context lane _staging =
    Graph.staging_reset_context
      ~rollback_bind:(fun staging (B bind) ->
        Graph.staged_bind_rollback
          ~staged:(bind_staged_snapshot lane staging bind)
          ~lifecycle:(bind_switch_lifecycle lane))
      ~rollback_timer_refresh_dirty:(fun _staging context ->
        Graph.staged_timer_refresh_dirty_rollback ~rollback:(fun () ->
            Graph.restore_dirty graph lane dirty_ops
              (Timer_policy.refresh_dirty_items context);
            Timer_policy.clear_refresh_dirty_items context))
      ~clear_timer_refresh_timer:(fun _staging timer ->
        Graph.staged_timer_reset ~reset:(fun () ->
            clear_timer_refresh_timer_staging timer))

  let staging_commit_plan lane _staging =
    Graph.staging_commit_plan
      ~preflight:(preflight_commit_staging lane)
      ~binds:
        (Graph.staging_bind_commit_plan
           ~commit:(fun staging (B bind) ->
             Graph.staged_bind_commit
               ~switch:(bind_staged_switch lane staging bind)
               ~lifecycle:(bind_switch_lifecycle lane)))
      ~signals:
        (Graph.staging_signal_commit_plan
           ~commit:(fun _staging signal -> signal_commit signal))
      ~timers:
        (Graph.staging_timer_commit_plan
           ~commit:(fun _staging timer -> timer_refresh_commit timer))

  let requeue_if_needed lane (V var as packed) =
    if not var.queued then (
      var.queued <- true;
      Graph.enqueue_pending graph lane packed)

  let mark_failed_without_current (lane : graph_lane) (O observer) =
    Observer_core.mark_failed_without_current (observer_delivery_port ()) lane
      observer

  let next_timer_refresh_token_unlocked lane =
    match Graph.next_timer_refresh_token graph lane with
    | Ok token -> token
    | Error err -> raise (Graph_error err)

  let stage_pending_var lane staging (V var) =
    let graph_value = Transaction.current var.graph_value in
    let source_value = Transaction.current var.source_value in
    if not (var.var_equal graph_value source_value) then (
      stage_var_graph_value lane staging var source_value;
      List.iter (mark_self_dirty lane) (source_watchers_unlocked var))

  let refresh_timer_source_for_compute lane staging signal =
    Graph.with_timer_refresh_timer graph lane signal.timer
      ~none:(fun () -> ())
      ~some:(fun timer_refresh timer ->
        match
          Timer.refresh_node_on_demand
            ~runtime_mismatch:timer_runtime_mismatch
            ~current_snapshot:timer_current_snapshot
            ~effective_state:timer_effective_state
            ~remember:(remember_timer_refresh_timer lane staging)
            ~run_operation:(fun timer ~now_ms operation ->
              stage_timer_refresh_operation lane staging timer now_ms operation)
            timer_refresh timer
        with
        | Ok () -> ()
        | Error err -> raise (Graph_error err))

  let rec compute : type a. graph_lane -> Graph.staging -> a signal -> a * bool
      =
   fun lane staging signal ->
    if not signal.valid then raise (Graph_error `Invalid_scope);
    refresh_timer_source_for_compute lane staging signal;
    Graph.compute_cached graph lane compute_ops (P signal)
      ~current:(fun _compute_node -> effective_signal_value signal)
      ~cycle:(fun _compute_node -> raise (Graph_error `Cycle))
      ~compute:(fun _compute_node -> compute_uncached lane staging signal)

  and compute_uncached :
      type a. graph_lane -> Graph.staging -> a signal -> a * bool =
   fun lane staging signal ->
    remember_computed lane staging (P signal);
    let signal_initialized () =
      Signal_snapshot.is_initialized (signal_effective_snapshot signal)
    in
    let recompute value =
      Graph.bump_counter graph lane Graph.Recompute_count;
      let snapshot = signal_effective_snapshot signal in
      let changed =
        Graph_algorithms.Value_cutoff.changed ~equal:signal.equal
          ~initialized:(Signal_snapshot.is_initialized snapshot)
          ~current:(Signal_snapshot.value snapshot) ~next:value
      in
      if changed then stage_signal lane staging signal value;
      (if changed then value else current_or_raise signal), changed
    in
    let use_cached () = (current_or_raise signal, false) in
    let dependency_changed dependencies =
      dependencies_changed lane signal dependencies
    in
    let recompute_with_dependencies dependencies value =
      stage_dependency_versions lane staging signal dependencies;
      recompute value
    in
    let static_child child_signal =
      Graph_algorithms.Static_eval.child ~dependency:(P child_signal)
        (compute lane staging child_signal)
    in
    let finish_static ?(stage_dependencies = true) result =
      Graph_algorithms.Static_eval.plan ~stage_dependencies ~dirty:signal.dirty
        ~initialized:(signal_initialized ())
        ~dependencies_changed:dependency_changed result
      |> Graph_algorithms.Static_eval.plan_result ~use_cached
           ~recompute:(fun ~dependencies ~output ~stage_dependencies ->
             if stage_dependencies then
               recompute_with_dependencies dependencies output
             else recompute output)
    in
    match signal.kind with
    | Const value ->
        finish_static ~stage_dependencies:false (Graph_algorithms.Static_eval.leaf value)
    | Var var ->
        finish_static ~stage_dependencies:false
          (Graph_algorithms.Static_eval.leaf (effective_var_value var))
    | Map (a, f) ->
        let a_child = static_child a in
        finish_static (Graph_algorithms.Static_eval.map a_child f)
    | Map2 (a, b, f) ->
        let a_child = static_child a in
        let b_child = static_child b in
        finish_static
          (Graph_algorithms.Static_eval.map2 a_child b_child f)
    | Map3 (a, b, c, f) ->
        let a_child = static_child a in
        let b_child = static_child b in
        let c_child = static_child c in
        finish_static
          (Graph_algorithms.Static_eval.map3 a_child b_child c_child f)
    | Map4 (a, b, c, d, f) ->
        let a_child = static_child a in
        let b_child = static_child b in
        let c_child = static_child c in
        let d_child = static_child d in
        finish_static
          (Graph_algorithms.Static_eval.map4 a_child b_child c_child d_child f)
    | Map5 (a, b, c, d, e, f) ->
        let a_child = static_child a in
        let b_child = static_child b in
        let c_child = static_child c in
        let d_child = static_child d in
        let e_child = static_child e in
        finish_static
          (Graph_algorithms.Static_eval.map5 a_child b_child c_child d_child e_child f)
    | Map6 (a, b, c, d, e, f_signal, f) ->
        let a_child = static_child a in
        let b_child = static_child b in
        let c_child = static_child c in
        let d_child = static_child d in
        let e_child = static_child e in
        let f_child = static_child f_signal in
        finish_static
          (Graph_algorithms.Static_eval.map6 a_child b_child c_child d_child e_child
             f_child f)
    | Map7 (a, b, c, d, e, f_signal, g, f) ->
        let a_child = static_child a in
        let b_child = static_child b in
        let c_child = static_child c in
        let d_child = static_child d in
        let e_child = static_child e in
        let f_child = static_child f_signal in
        let g_child = static_child g in
        finish_static
          (Graph_algorithms.Static_eval.map7 a_child b_child c_child d_child e_child
             f_child g_child f)
    | Map8 (a, b, c, d, e, f_signal, g, h, f) ->
        let a_child = static_child a in
        let b_child = static_child b in
        let c_child = static_child c in
        let d_child = static_child d in
        let e_child = static_child e in
        let f_child = static_child f_signal in
        let g_child = static_child g in
        let h_child = static_child h in
        finish_static
          (Graph_algorithms.Static_eval.map8 a_child b_child c_child d_child e_child
             f_child g_child h_child f)
    | Map9 (a, b, c, d, e, f_signal, g, h, i, f) ->
        let a_child = static_child a in
        let b_child = static_child b in
        let c_child = static_child c in
        let d_child = static_child d in
        let e_child = static_child e in
        let f_child = static_child f_signal in
        let g_child = static_child g in
        let h_child = static_child h in
        let i_child = static_child i in
        finish_static
          (Graph_algorithms.Static_eval.map9 a_child b_child c_child d_child e_child
             f_child g_child h_child i_child f)
    | All signals ->
        let children =
          List.fold_right
            (fun child_signal children ->
              static_child child_signal :: children)
            signals []
        in
        finish_static (Graph_algorithms.Static_eval.all children)
    | Bind bind ->
        compute_bind_dynamic lane staging signal bind

  and compute_bind_dynamic :
      type source value.
      graph_lane ->
      Graph.staging ->
      value signal ->
      (source, value) bind ->
      value * bool =
   fun lane staging signal bind ->
    let switch =
      Bind.dynamic_switch_plan
        ~new_scope:(fun _lane -> new_scope signal)
        ~with_scope:(fun _lane scope f ->
          Graph.with_current_scope graph scope_ops scope f)
        ~on_switch_failure:(fun lane scope ->
          remember_pure_disposal_hooks lane staging
            (invalidate_scope lane scope))
        ~selector:bind.selector
        ~validate_inner:(fun _lane scope inner ->
          Scope_validation.validate_inner ~scope (P inner))
        ~compute_inner:(fun lane inner -> compute lane staging inner)
    in
    let reuse =
      Bind.dynamic_reuse_plan ~dirty:signal.dirty
        ~dependencies_changed:(fun lane dependencies ->
          dependencies_changed lane signal dependencies)
    in
    let source =
      Bind.dynamic_source_plan ~equal:bind.source.equal
        ~compute_source:(fun lane -> compute lane staging bind.source)
        ~source_dependency:(P bind.source)
        ~inner_dependency:(fun inner -> P inner)
    in
    let value =
      Bind.dynamic_value_context
        ~state:(fun () ->
          let snapshot = signal_effective_snapshot signal in
          Bind.dynamic_value_state
            ~initialized:(Signal_snapshot.is_initialized snapshot)
            ~current:(Signal_snapshot.value snapshot))
        ~cached_value:(fun () -> current_or_raise signal)
        ~value_equal:signal.equal
        ~bump_recompute:(fun () ->
          Graph.bump_counter graph lane Graph.Recompute_count)
    in
    let staging_context =
      Bind.dynamic_staging_context
        ~stage_switch:(fun ~source_value ~inner ~scope ->
          stage_bind_switch lane staging bind source_value inner scope)
        ~stage_dependencies:(stage_dependency_versions lane staging signal)
        ~stage_value:(stage_signal lane staging signal)
    in
    let context =
      Bind.dynamic_context ~source ~switch ~reuse ~value
        ~staging:staging_context
    in
    match
      Bind.run_dynamic context lane (bind_effective_snapshot bind)
    with
    | Error `Invalid_scope -> raise (Graph_error `Invalid_scope)
    | Ok result -> result

  let collect_necessary_node_ids lane =
    Graph.necessary_ids graph lane (graph_reachable_plan ())

  let update_necessity_counters_unlocked lane =
    ignore
      (Graph.update_necessity graph lane (graph_reachable_plan ())
        : Graph.necessary_snapshot)

  let signal_timer_demand_source () =
    Graph.timer_demand_source ~reachable:(graph_reachable_plan ())
      ~timer:signal_timer

  let fail_with_pending_disposal_hooks hooks_ref eff =
    Cleanup.fail_with_pending hooks_ref eff

  let graph_error_with_pending_disposal_hooks hooks_ref err =
    fail_with_pending_disposal_hooks hooks_ref
      (Effect.fail (err :> stabilize_error))

  let timer_demand_unlocked lane =
    Graph.timer_demand graph lane (signal_timer_demand_source ())

  let timer_demand_plan_unlocked lane =
    let demand = timer_demand_unlocked lane in
    Graph.timer_demand_plan demand ~plan:(fun ~is_necessary ~timers ->
        Timer.node_demand_plan ~timers ~is_necessary
          ~runtime_mismatch:timer_runtime_mismatch
          ~state:timer_state_port)

  let current_runtime_contract () =
    Effect.Expert.make ~leaf_name:"Eta_signal.current_runtime_contract"
      (fun context -> Eta.Exit.Ok (Effect.Expert.contract context))

  let timer_demand_access =
    Timer.demand_effect_access ~with_access:(fun f ->
        with_graph_lane_access (fun lane ->
            try f lane with Graph_error err -> Error err)
        |> Effect.flatten_result)

  let refresh_timer_demand () =
    Timer.node_demand_refresh
      ~advance_generation:(checked_succ "timer generation")
      ~access:timer_demand_access
      ~demand:
        (Timer.node_demand_effect_port ~plan:(fun _runtime_contract lane ->
             timer_demand_plan_unlocked lane))
    |> Timer.run_node_demand_refresh

  let defect_with_pending_disposal_hooks hooks_ref exn backtrace =
    fail_with_pending_disposal_hooks hooks_ref
      (Effect.sync (fun () -> Printexc.raise_with_backtrace exn backtrace))

  let run_pending_stabilize_cleanup hooks_ref refresh_timers =
    if !refresh_timers then
      (Effect.sync (fun () -> refresh_timers := false)
       |> Effect.bind (fun () ->
              refresh_timer_demand ()
              |> Effect.map_error (fun err -> (err :> stabilize_error))
              |> Effect.bind (fun () ->
                     Cleanup.run_pending_as_finalizers hooks_ref)))
      |> Effect.uninterruptible
    else Cleanup.run_pending_as_finalizers hooks_ref

  let run_pending_dispose_cleanup hooks_ref refresh_timers =
    if !refresh_timers || Cleanup.pending hooks_ref then
      ((if !refresh_timers then
          Effect.sync (fun () -> refresh_timers := false)
          |> Effect.bind (fun () -> refresh_timer_demand ())
        else Effect.unit)
       |> Effect.bind (fun () ->
              Cleanup.run_pending_as_finalizers hooks_ref))
      |> Effect.uninterruptible
    else Effect.unit

  let run_pending_registration_abort_cleanup hooks_ref refresh_timers =
    let best_effort eff = Effect.exit eff |> Effect.map (fun _ -> ()) in
    if !refresh_timers || Cleanup.pending hooks_ref then
      ((if !refresh_timers then
          Effect.sync (fun () -> refresh_timers := false)
          |> Effect.bind (fun () -> refresh_timer_demand ())
          |> Effect.ignore_errors
          |> best_effort
        else Effect.unit)
       |> Effect.bind (fun () ->
              Cleanup.run_pending_as_finalizers hooks_ref
              |> best_effort))
      |> Effect.uninterruptible
    else Effect.unit

  let dispose_observer_with_cleanup cleanup observer =
    let hooks_ref = ref [] in
    let refresh_timers = ref false in
    with_graph_lane_access
      (fun lane ->
        (match observer.obs_state with
         | Observer_lifecycle.Disposed _ -> ()
         | Observer_lifecycle.Registering _ | Observer_lifecycle.Active _
         | Observer_lifecycle.Invalid_scope _ ->
          let hooks = dispose_observer_unlocked lane observer in
          hooks_ref := hooks;
          refresh_timers := true;
          update_necessity_counters_unlocked lane))
    |> Effect.bind (fun () ->
           cleanup hooks_ref refresh_timers)
    |> Effect.on_exit (fun _exit ->
           cleanup hooks_ref refresh_timers)

  let dispose_observer_effect observer =
    dispose_observer_with_cleanup run_pending_dispose_cleanup observer

  let abort_observer_registration_effect observer =
    let hooks_ref = ref [] in
    let refresh_timers = ref false in
    let run_cleanup () =
      run_pending_registration_abort_cleanup hooks_ref refresh_timers
    in
    with_graph_lane_access
      (fun lane ->
        match observer.obs_state with
        | Observer_lifecycle.Registering _ | Observer_lifecycle.Active _
        | Observer_lifecycle.Invalid_scope _ ->
            let hooks = dispose_observer_unlocked lane observer in
            hooks_ref := hooks;
            refresh_timers := true;
            update_necessity_counters_unlocked lane;
            true
        | Observer_lifecycle.Disposed _ -> false)
    |> Effect.bind (function
         | true -> run_cleanup ()
         | false -> Effect.unit)
    |> Effect.on_exit (fun _exit ->
           run_cleanup ())

  let compare_signal_scope_then_id (P left) (P right) =
    match Int.compare (Scope.depth left.scope) (Scope.depth right.scope) with
    | 0 -> Int.compare (signal_id_int left.id) (signal_id_int right.id)
    | order -> order

  let observer_order_dependencies : type a. a signal -> packed_signal list =
   fun signal ->
    match signal.kind with
    | Bind bind ->
        Bind.dependencies ~source:(P bind.source)
          ~inner_dependency:(fun inner -> P inner)
          (bind_effective_snapshot bind)
    | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _ | Map6 _
    | Map7 _ | Map8 _ | Map9 _ | All _ ->
        signal.dependencies

  let order_ops =
    Graph.order_ops ~identity:graph_node_identity
      ~compare_id:(fun left right ->
        Int.compare (signal_id_int left) (signal_id_int right))
      ~children:(fun (P signal) -> observer_order_dependencies signal)

  let compare_observer_graph_order lane (O left) (O right) =
    let signal_order =
      Graph.compare_order graph lane order_ops (P left.obs_signal)
        (P right.obs_signal)
    in
    if signal_order = 0 then compare_observer_id left.obs_id right.obs_id
    else signal_order

  let collect_observed_bind_nodes lane observers =
    prune_all_nodes_unlocked lane;
    let bind_selection =
      Graph.bind_node_selection ~bind:(fun (P signal as packed) ->
          match signal.kind with
          | Bind _ -> Some packed
          | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _
          | Map6 _ | Map7 _ | Map8 _ | Map9 _ | All _ ->
              None)
    in
    Graph.collect_reachable_bind_nodes graph lane reachable_ops
      ~roots:(observer_active_roots observers)
      bind_selection
    |> List.sort compare_signal_scope_then_id

  let plan_staged_bind_switches lane staging observers =
    let invalidations = ref (collect_staged_bind_invalidations lane staging) in
    let refresh_invalidations () =
      invalidations := collect_staged_bind_invalidations lane staging
    in
    List.iter
      (fun (P signal as packed) ->
        if
          signal.valid
          && not (staged_bind_invalidates !invalidations packed)
        then
          match signal.kind with
          | Bind _ ->
              ignore (compute lane staging signal : _ * bool);
              refresh_invalidations ()
          | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _
          | Map6 _ | Map7 _ | Map8 _ | Map9 _ | All _ ->
              ())
      (collect_observed_bind_nodes lane observers)

  let graph_error_of_die die =
    match die.Eta.Cause.exn with
    | Graph_error err -> Some err
    | _ -> None

  let run_observer_effect _observer _token observer_eff =
    Effect.Expert.make ~leaf_name:"eta_signal.observer" @@ fun context ->
    try
      match Effect.Expert.eval context observer_eff with
      | Eta.Exit.Ok () -> Eta.Exit.Ok ()
      | Eta.Exit.Error cause ->
          Eta.Exit.Error
            (Error.observer_cause_to_stabilize ~graph_error_of_die cause)
    with
    | Graph_error err ->
        Eta.Exit.Error (Eta.Cause.Fail (err :> stabilize_error))

  let event_observer_active (_lane : graph_lane) observer =
    observer_active (O observer)

  let construct_observer_effect (_lane : graph_lane) observer token update =
    try Ok (Some (observer.obs_callback token update))
    with Graph_error err -> Error (err :> stabilize_error)

  let observer_delivery_event_port () =
    let activation =
      Observer_core.delivery_event_activation_plan
        ~active:event_observer_active
    in
    let callback =
      Observer_core.delivery_event_callback_plan
        ~construct:construct_observer_effect
        ~run_callback:(fun observer token observer_eff ->
          run_observer_effect observer token observer_eff)
    in
    Observer_core.delivery_event_port ~activation ~callback

  let observer_delivery_event_access =
    Observer_core.delivery_event_access
      ~with_delivery_access:(fun f ->
        with_graph_lane_access (fun lane -> f lane))

  let observer_update_collection_port staging invalidations =
    Observer_core.update_collection_port
      ~live:(fun (_lane : graph_lane) observer ->
        observer_active_live_state observer)
      ~skip:(fun (_lane : graph_lane) observer ->
        staged_bind_invalidates invalidations (P observer.obs_signal))
      ~compute:(fun lane observer -> compute lane staging observer.obs_signal)
      ~snapshot:(fun (_lane : graph_lane) live ->
        observer_effective_snapshot live)
      ~stage_snapshot:(fun lane live snapshot ->
        Graph.stage_cell graph lane staging live.observer_snapshot snapshot)
      ~equal:(fun observer -> observer.obs_equal)

  let collect_typed_observer_event staging lane (type a)
      (observer : a observer) =
    let invalidations = collect_staged_bind_invalidations lane staging in
    let context =
      Observer_core.delivery_event_context
        ~access:observer_delivery_event_access
        ~delivery:(observer_delivery_port ())
        ~event:(observer_delivery_event_port ())
        ~token:current_generation
    in
    let source =
      Observer_core.delivery_event_source context
        (observer_update_collection_port staging invalidations)
    in
    Observer_core.collect_delivery_event source lane observer

  let observer_delivery_event_source staging =
    Observer_core.delivery_event_source_of_collect_event
      ~collect_event:(fun lane (O observer) ->
        collect_typed_observer_event staging lane observer)

  let run_events events =
    Observer_core.Delivery_event.run
      ~after_claim:(fun () ->
        Private_test_hooks.run After_observer_delivery_claim)
      events

  let begin_stabilize lane timer_refresh =
    let pending =
      Graph.stabilization_pending_plan
        ~release_marks:(fun (_lane : graph_lane) pending ->
          Graph.stabilization_pending_mark_release ~release:(fun () ->
              List.iter (fun (V var) -> var.queued <- false) pending))
        ~stage:(fun lane staging pending ->
          Graph.stabilization_pending_stage ~stage:(fun () ->
              List.iter (stage_pending_var lane staging) pending))
    in
    let observers =
      Graph.stabilization_observer_plan
        ~delivery:(fun lane staging ->
          let selection =
            Observer_core.delivery_selection_plan ~active:observer_active
              ~compare:(compare_observer_graph_order lane)
          in
          Observer_core.delivery_event_collection ~selection
            (observer_delivery_event_source staging))
        ~plan_staged_binds:(fun lane staging observers ->
          Graph.staged_bind_planning ~plan:(fun () ->
              plan_staged_bind_switches lane staging observers))
    in
    let commit =
      Graph.stabilization_commit_plan
        ~staging:staging_commit_plan
        ~update_necessity:(fun lane ->
          Graph.stabilization_necessity_update ~update:(fun () ->
              update_necessity_counters_unlocked lane))
    in
    let pure =
      Graph.stabilization_pure_ops ~pending ~observers ~commit
    in
    let rollback =
      Graph.stabilization_rollback_ops
        ~staging:staging_reset_context
        ~mark_observers_failed_without_current:
          (fun lane observers ->
            Graph.stabilization_observer_failure_mark ~mark:(fun () ->
                List.iter (mark_failed_without_current lane) observers))
        ~requeue_pending:(fun lane pending ->
          Graph.stabilization_pending_requeue ~requeue:(fun () ->
              List.iter (requeue_if_needed lane) pending))
    in
    Graph.run_stabilization graph lane ~timer_refresh
      (Graph.stabilization_ops
         ~classify_graph_error:(function
           | Graph_error err -> Some err
           | _ -> None)
         ~pure ~rollback)

  let begin_stabilize_with_pending_hooks lane timer_refresh hooks_ref
      stabilization_finish =
    let result = begin_stabilize lane timer_refresh in
    let hooks =
      Graph.record_stabilization_result stabilization_finish lane result
    in
    hooks_ref := hooks;
    result

  let stabilization_delivery_ops hooks_ref refresh_timers stabilization_finish =
    Graph.stabilization_delivery_ops graph stabilization_finish
      (Graph.stabilization_delivery_context
         ~run_pending_cleanup:(fun () ->
           run_pending_stabilize_cleanup hooks_ref refresh_timers)
         ~run_events
         ~with_lane_access:(fun f -> with_graph_lane_access f))

  let stabilize =
    Effect.sync (fun () ->
        (ref [], ref false, Graph.create_stabilization_finish ()))
    |> Effect.bind
         (fun (hooks_ref, refresh_timers, stabilization_finish) ->
           let delivery_ops =
             stabilization_delivery_ops hooks_ref refresh_timers
               stabilization_finish
           in
           (current_runtime_contract ()
            |> Effect.bind (fun runtime_contract ->
                   with_graph_lane_access (fun lane ->
                       try
                         let timer_refresh =
                           Some
                             (Timer_policy.create_refresh_context
                                ~token:(next_timer_refresh_token_unlocked lane)
                                ~runtime_contract
                                ~now_ms:runtime_contract.Runtime_contract.now_ms)
                         in
                         begin_stabilize_with_pending_hooks lane timer_refresh
                           hooks_ref stabilization_finish
                       with Graph_error err ->
                         Stabilization_pass.graph_error ~hooks:[] err)
                   |> Effect.bind (fun result ->
                          Stabilization_pass.result result
                            ~graph_error:(fun ~hooks:_ err ->
                              graph_error_with_pending_disposal_hooks hooks_ref
                                err)
                            ~defect:(fun ~hooks:_ exn backtrace ->
                              defect_with_pending_disposal_hooks hooks_ref exn
                                backtrace)
                            ~pure_ok:
                              (fun ~hooks:_ ~events ~delivering_token:_ ->
                                refresh_timers := true;
                                Stabilization_pass.deliver delivery_ops events)))
           |> Effect.on_exit (fun _exit ->
                  Stabilization_pass.finish_delivery delivery_ops)))

  module Var = struct
    type 'a t = 'a var

    let create ?(equal = default_equal) value =
      {
        var_id = next_var_id ();
        var_equal = equal;
        source_value = Transaction.create_staged value;
        graph_value = Transaction.create_staged value;
        queued = false;
        updating = false;
        watchers = [];
      }

    let value (source : 'a t) =
      ensure_graph_context ();
      (match Graph.ensure_not_pure graph with
      | Ok () -> ()
      | Error err -> raise (Graph_error err));
      Transaction.current source.source_value

    let watch (source : 'a t) =
      let signal = new_signal (Var source) [] in
      source.watchers <- weak_packed_signal (P signal) :: source.watchers;
      signal

    let queue_var lane (source : 'a t) = queue_var_unlocked lane source

    let set_unlocked lane (source : 'a t) value =
      set_var_source_unlocked lane source value

    let set (source : 'a t) value =
      with_graph_lane_access (fun lane ->
          if source.updating then Error `Reentrant_update
          else (
            set_unlocked lane source value;
            Ok ()))
      |> Effect.flatten_result

    let set_from_update (source : 'a t) value =
      with_graph_lane_access (fun lane ->
          set_unlocked lane source value;
          value)

    let release_update (source : 'a t) =
      with_graph_lane_sync (fun () -> source.updating <- false)

    let update_effect (source : 'a t) f =
      let acquired = ref false in
      let acquire =
        with_graph_lane_sync (fun () ->
            if source.updating then Error `Reentrant_update
            else (
              source.updating <- true;
              acquired := true;
              Ok (Transaction.current source.source_value)))
        |> Effect.flatten_result
      in
      let release_if_acquired () =
        if !acquired then release_update source else Effect.unit
      in
      (acquire
       |> Effect.bind (fun old_value ->
              Effect.sync (fun () -> f old_value)
              |> Effect.bind (fun update_eff -> update_eff)
              |> Effect.bind (fun new_value ->
                     set_from_update source new_value)))
      |> Effect.on_exit (fun _ -> release_if_acquired ())
  end

  module Observer = struct
    type 'a t = 'a observer
    type delivery_token = Observer_core.Delivery.token

    type 'a delivery =
      (delivery_token, 'a update, observer_after_ack_action)
      Observer_core.Delivery_handle.t

    let delivery observer token update =
      Observer_core.make_delivery_handle
        ~access:observer_delivery_event_access
        (observer_delivery_port ()) ~observer ~token update

    let transfer_active_observer observer =
      (* This is deliberately a same-domain leaf, not another lane acquisition:
         the transfer check must not introduce a new lane-release callback
         window between the final state check and returning the handle. *)
      Effect.sync (fun () ->
          ensure_graph_context ();
          Observer_core.activate_observer (observer_activation_port ())
            observer)
      |> Effect.flatten_result

    let observe_with_hooks_delivery_callback ?(equal = default_equal)
        ?(on_finish = []) signal callback =
      with_graph_lane_access (fun lane ->
          try
            if not signal.valid then Error `Invalid_scope
            else
              let live =
                {
                  observer_snapshot =
                    Transaction.create_staged Observer_snapshot.initial;
                  obs_on_finish = on_finish;
                }
              in
              let rec observer =
                {
                  obs_id = next_observer_id ();
                  obs_signal = signal;
                  obs_equal = equal;
                  obs_callback =
                    (fun token update -> callback observer token update);
                  obs_state = Observer_lifecycle.Registering live;
                }
              in
              Graph.add_observer graph lane (O observer);
              update_necessity_counters_unlocked lane;
              Ok observer
          with Graph_error err -> Error err)
      |> Effect.flatten_result
      |> Effect.bind (fun observer ->
             (refresh_timer_demand ()
             |> Effect.bind (fun () -> transfer_active_observer observer)
             |> Effect.bind (fun observer ->
                    Private_test_hooks.run
                      After_observer_activation_before_return
                    |> Effect.map (fun () -> observer)))
             |> Effect.on_exit (function
                  | Eta.Exit.Ok _ -> Effect.unit
                  | Eta.Exit.Error _ ->
                      abort_observer_registration_effect observer))

    let observe_with_hooks_callback ?equal ?on_finish signal callback =
      observe_with_hooks_delivery_callback ?equal ?on_finish signal
        (fun observer _token update -> callback observer update)

    let observe_delivery ?equal ?on_finish signal callback =
      observe_with_hooks_delivery_callback ?equal ?on_finish signal
        (fun observer token update ->
          callback (delivery observer token update))

    let observe_with_hooks ?equal ?on_finish signal callback =
      observe_with_hooks_callback ?equal ?on_finish signal
        (fun _observer update -> callback update)

    let observe ?equal signal callback = observe_with_hooks ?equal signal callback

    let read observer =
      with_graph_lane_sync (fun () ->
          Observer_lifecycle.read_value
            ~value_of_live:(fun live ->
              Observer_snapshot.value (observer_current_snapshot live))
            observer.obs_state)
      |> Effect.flatten_result

    let unsafe_read_exn observer =
      ensure_graph_context ();
      Observer_lifecycle.unsafe_read_value_exn
        ~value_of_live:(fun live ->
          Observer_snapshot.value (observer_current_snapshot live))
        observer.obs_state

    let dispose observer = dispose_observer_effect observer
  end

  let const ?equal value = new_const ?equal value
  let map ?equal f a = new_signal ?equal (Map (a, f)) [ P a ]
  let map2 ?equal f a b = new_signal ?equal (Map2 (a, b, f)) [ P a; P b ]

  let map3 ?equal f a b c =
    new_signal ?equal (Map3 (a, b, c, f)) [ P a; P b; P c ]

  let map4 ?equal f a b c d =
    new_signal ?equal (Map4 (a, b, c, d, f)) [ P a; P b; P c; P d ]

  let map5 ?equal f a b c d e =
    new_signal ?equal (Map5 (a, b, c, d, e, f)) [ P a; P b; P c; P d; P e ]

  let map6 ?equal f a b c d e f_signal =
    new_signal ?equal
      (Map6 (a, b, c, d, e, f_signal, f))
      [ P a; P b; P c; P d; P e; P f_signal ]

  let map7 ?equal f a b c d e f_signal g =
    new_signal ?equal
      (Map7 (a, b, c, d, e, f_signal, g, f))
      [ P a; P b; P c; P d; P e; P f_signal; P g ]

  let map8 ?equal f a b c d e f_signal g h =
    new_signal ?equal
      (Map8 (a, b, c, d, e, f_signal, g, h, f))
      [ P a; P b; P c; P d; P e; P f_signal; P g; P h ]

  let map9 ?equal f a b c d e f_signal g h i =
    new_signal ?equal
      (Map9 (a, b, c, d, e, f_signal, g, h, i, f))
      [ P a; P b; P c; P d; P e; P f_signal; P g; P h; P i ]

  let both a b = map2 (fun a b -> (a, b)) a b
  let all ?equal signals = new_signal ?equal (All signals) (List.map (fun s -> P s) signals)
  let bind ?equal source selector = make_bind ?equal source selector

  let observer_count_plan =
    Graph.observer_count_plan ~active:observer_active
      ~invalid:(fun (O observer) ->
        Observer_lifecycle.invalid_scope observer.obs_state)

  let observer_counts lane =
    Graph.observer_counts graph lane observer_count_plan

  let necessary_node_count lane =
    Graph.necessary_count (collect_necessary_node_ids lane)

  let dead_node_count lane = Graph.dead_node_count graph lane

  let live_dirty_node_count all_nodes =
    List.fold_left
      (fun count (P signal) ->
        if signal.valid && signal.dirty then saturating_succ count else count)
      0 all_nodes

  let stats_counter name value =
    match Debug.stats_counter ~name value with
    | Ok value -> value
    | Error (`Counter_overflow name) -> counter_overflow name

  let stats () =
    with_graph_lane_access (fun lane ->
        try
          let all_nodes = all_nodes_unlocked lane in
          let observer_counts = observer_counts lane in
          Ok
            {
              pure_snapshot_commit_count =
                stats_counter "stats pure_snapshot_commit_count"
                  (Graph.pure_snapshot_commit_count graph lane);
              callback_delivery_count =
                stats_counter "stats callback_delivery_count"
                  (Graph.counter graph lane Graph.Callback_delivery_count);
              total_node_count =
                stats_counter "stats total_node_count" (List.length all_nodes);
              active_observer_count =
                stats_counter "stats active_observer_count"
                  (Graph.observer_counts_active observer_counts);
              invalid_observer_count =
                stats_counter "stats invalid_observer_count"
                  (Graph.observer_counts_invalid observer_counts);
              necessary_node_count =
                stats_counter "stats necessary_node_count"
                  (necessary_node_count lane);
              dead_node_count =
                stats_counter "stats dead_node_count" (dead_node_count lane);
              live_dirty_node_count =
                stats_counter "stats live_dirty_node_count"
                  (live_dirty_node_count all_nodes);
              recompute_count =
                stats_counter "stats recompute_count"
                  (Graph.counter graph lane Graph.Recompute_count);
              dynamic_scope_invalidations =
                stats_counter "stats dynamic_scope_invalidations"
                  (Graph.counter graph lane Graph.Dynamic_scope_invalidations);
              nodes_became_necessary =
                stats_counter "stats nodes_became_necessary"
                  (Graph.counter graph lane Graph.Nodes_became_necessary);
              nodes_became_unnecessary =
                stats_counter "stats nodes_became_unnecessary"
                  (Graph.counter graph lane Graph.Nodes_became_unnecessary);
              stream_bridge_drop_count =
                stats_counter "stats stream_bridge_drop_count"
                  (Stream_bridge.drop_count (graph_stream_bridge_metrics ()));
              lane_waiter_count =
                stats_counter "stats lane_waiter_count"
                  (Graph.lane_waiting_count graph lane);
              lane_cancelled_waiter_count =
                stats_counter "stats lane_cancelled_waiter_count"
                  (Graph.lane_cancelled_count graph lane);
            }
        with Graph_error err -> Error err)
    |> Effect.flatten_result

  let signal_selected :
      type a. dot_options -> Graph.necessary_snapshot -> a signal -> bool =
   fun options necessary signal ->
    match options.dot_scope with
    | `Necessary -> Graph.necessary_mem necessary signal.id
    | `All_valid -> signal.valid
    | `All_including_invalid -> true

  let signal_state_snapshot : type a. a signal -> Debug.signal_state_snapshot =
   fun signal ->
    let snapshot = signal_current_snapshot signal in
    let signal_var =
      match signal.kind with
      | Var source ->
          Some
            {
              Debug.signal_var_id_label = var_id_label source.var_id;
              signal_var_queued = source.queued;
              signal_var_updating = source.updating;
            }
      | Const _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _ | Map6 _ | Map7 _
      | Map8 _ | Map9 _ | All _ | Bind _ ->
          None
    in
    {
      Debug.signal_valid = signal.valid;
      signal_initialized = Signal_snapshot.is_initialized snapshot;
      signal_dirty = signal.dirty;
      signal_computing = signal.computing;
      signal_dependency_count = List.length signal.dependencies;
      signal_dependent_count = List.length signal.dependents;
      signal_var;
    }

  let signal_scope_snapshot : type a. a signal -> Debug.signal_scope_snapshot =
   fun signal ->
    match signal.scope with
    | None -> Debug.Signal_root_scope
    | Some scope ->
        let parent =
          match Scope.parent scope with
          | None -> "root"
          | Some parent -> scope_id_label (Scope.id parent)
        in
        Debug.Signal_child_scope
          {
            signal_scope_id_label = scope_id_label (Scope.id scope);
            signal_scope_valid = Scope.valid scope;
            signal_scope_owner_label = signal_id_label (scope_owner_id scope);
            signal_scope_parent_label = parent;
          }

  let debug_timer_snapshot (timer : Timer_policy.debug_snapshot) =
    Timer_policy.debug_snapshot_result timer
      ~plan:(fun ~state_label:_ ~active ~running_generation ~has_cancel
                 ~finished ~generation ->
        {
          Debug.timer_active = active;
          timer_running_generation = running_generation;
          timer_has_cancel = has_cancel;
          timer_finished = finished;
          timer_generation = generation;
        })

  let signal_timer_fields : type a. a signal -> string list =
   fun signal ->
    match signal.timer with
    | None -> []
    | Some timer ->
        Debug.timer_fields
          ~state_label:(timer_state_label (timer_current_state timer))
          (debug_timer_snapshot (timer_debug_snapshot timer))

  let dead_signal_state_snapshot dead =
    {
      Debug.signal_valid = false;
      signal_initialized = dead.dead_initialized;
      signal_dirty = dead.dead_dirty;
      signal_computing = dead.dead_computing;
      signal_dependency_count = dead.dead_dependency_count;
      signal_dependent_count = dead.dead_dependent_count;
      signal_var = None;
    }

  let dead_signal_scope_snapshot dead =
    match
      ( dead.dead_scope_id,
        dead.dead_scope_owner,
        dead.dead_scope_parent,
        dead.dead_scope_valid )
    with
    | None, None, None, None -> Debug.Signal_root_scope
    | Some scope_id, Some owner, parent, Some scope_valid ->
        Debug.Signal_child_scope
          {
            signal_scope_id_label = scope_id_label scope_id;
            signal_scope_valid = scope_valid;
            signal_scope_owner_label = signal_id_label owner;
            signal_scope_parent_label =
              Option.fold ~none:"root"
                ~some:(fun parent -> scope_id_label parent)
                parent;
          }
    | _ -> invalid_arg "Eta_signal: inconsistent dead signal scope"

  let dead_timer_fields = function
    | None -> []
    | Some timer -> Debug.timer_fields (debug_timer_snapshot timer)

  let signal_label : type a. dot_options -> a signal -> string =
   fun options signal ->
    Debug.signal_label
      {
        Debug.signal_kind_label = kind_name signal.kind;
        signal_id_label = signal_id_label signal.id;
        signal_tombstone = false;
        signal_state =
          (if options.dot_state then Some (signal_state_snapshot signal)
           else None);
        signal_scope =
          (if options.dot_dynamic_scopes then
             Some (signal_scope_snapshot signal)
           else None);
        signal_timer_fields =
          (if options.dot_timers then signal_timer_fields signal else []);
      }

  let dead_signal_label options dead =
    Debug.signal_label
      {
        Debug.signal_kind_label = dead.dead_kind;
        signal_id_label = signal_id_label dead.dead_id;
        signal_tombstone = true;
        signal_state =
          (if options.dot_state then Some (dead_signal_state_snapshot dead)
           else None);
        signal_scope =
          (if options.dot_dynamic_scopes then
             Some (dead_signal_scope_snapshot dead)
           else None);
        signal_timer_fields =
          (if options.dot_timers then dead_timer_fields dead.dead_timer else []);
      }

  let observer_label ?missing_observed_signal_id (O observer) =
    let value_state_label, delivery_state_label =
      match observer.obs_state with
      | Observer_lifecycle.Registering live | Observer_lifecycle.Active live ->
          let snapshot = observer_current_snapshot live in
          ( Observer_core.Value.label (Observer_snapshot.value snapshot),
            Observer_core.Delivery.label
              (Observer_snapshot.delivery snapshot) )
      | Observer_lifecycle.Disposed value | Observer_lifecycle.Invalid_scope value
        ->
          (Observer_core.Value.label value, "none")
    in
    Debug.observer_label
      {
        Debug.observer_id_label = observer_id_label observer.obs_id;
        observer_state_label = Observer_lifecycle.label observer.obs_state;
        observer_value_state_label = value_state_label;
        observer_delivery_state_label = delivery_state_label;
        observer_missing_observed_signal_id_label =
          Option.map signal_id_label missing_observed_signal_id;
      }

  let observer_selected ~include_invalid (O observer) =
    Observer_lifecycle.diagnostic_visible ~include_invalid observer.obs_state

  let to_dot ?(options = default_dot_options) () =
    with_graph_lane_access @@ fun lane ->
    let necessary = collect_necessary_node_ids lane in
    let all_nodes = all_nodes_unlocked lane in
    let selected signal = signal_selected options necessary signal in
    let include_dead_nodes =
      match options.dot_scope with
      | `All_including_invalid -> true
      | `Necessary | `All_valid -> false
    in
    let live_ids = Hashtbl.create 16 in
    let dead_ids = Hashtbl.create 16 in
    if include_dead_nodes then
      Graph.iter_dead_nodes graph lane ~f:(fun tombstone ->
          Hashtbl.replace dead_ids tombstone.dead_id ());
    let selected_live_signal signal =
      selected signal
      && not
           (include_dead_nodes && (not signal.valid)
          && Hashtbl.mem dead_ids signal.id)
    in
    List.iter
      (fun (P signal) ->
        if selected_live_signal signal then
          Hashtbl.replace live_ids signal.id ())
      all_nodes;
    let selected_id id = Hashtbl.mem live_ids id || Hashtbl.mem dead_ids id in
    let dot_signal_id id =
      if Hashtbl.mem live_ids id then signal_id_label id
      else dead_signal_id_label id
    in
    let live_dot_nodes =
      all_nodes
      |> List.filter_map (fun (P signal) ->
             if selected_live_signal signal then
               Some
                 {
                   Debug.dot_node_id = signal_id_label signal.id;
                   dot_node_label = signal_label options signal;
                   dot_node_dependency_ids =
                     List.filter_map
                       (fun (P dependency) ->
                         if selected_id dependency.id then
                           Some (dot_signal_id dependency.id)
                         else None)
                       signal.dependencies;
                 }
             else None)
    in
    let dead_dot_nodes =
      if include_dead_nodes then
        Graph.map_dead_nodes graph lane ~f:(fun tombstone ->
            {
              Debug.dot_node_id = dead_signal_id_label tombstone.dead_id;
              dot_node_label = dead_signal_label options tombstone;
              dot_node_dependency_ids =
                List.filter_map
                  (fun dependency_id ->
                    if selected_id dependency_id then
                      Some (dot_signal_id dependency_id)
                    else None)
                  tombstone.dead_dependency_ids;
            })
      else []
    in
    let dot_observers =
      if options.dot_observers then
        let diagnostics =
          Graph.observer_diagnostics
            ~visible:(observer_selected ~include_invalid:include_dead_nodes)
            ~diagnostic:(fun (O observer as packed) ->
              let observed_signal_selected = selected_id observer.obs_signal.id in
              let missing_observed_signal_id =
                if include_dead_nodes && not observed_signal_selected then
                  Some observer.obs_signal.id
                else None
              in
              {
                Debug.dot_observer_id = observer_id_label observer.obs_id;
                dot_observer_label =
                  observer_label ?missing_observed_signal_id packed;
                dot_observed_signal_id =
                  (if observed_signal_selected then
                     Some (dot_signal_id observer.obs_signal.id)
                   else None);
              })
        in
        Graph.collect_observer_diagnostics graph lane diagnostics
      else []
    in
    Debug.render_dot ~nodes:(live_dot_nodes @ dead_dot_nodes)
      ~observers:dot_observers

  module Time = struct
    type monotonic_time = int

    let to_ms timestamp = timestamp

    let validate_interval duration =
      Timer_policy.validate_interval_ms (Duration.to_ms duration)

    let validate_future now deadline_ms =
      Timer_policy.validate_future_deadline ~now_ms:now ~deadline_ms

    let validate_positive_duration duration =
      Timer_policy.validate_positive_duration_ms (Duration.to_ms duration)

    let timer_continue_after_update timer generation =
      with_graph_lane_sync (fun () ->
          Timer.after_update_state timer_state_port timer ~generation)

    let timer_set_source timer generation (source : 'a var) value =
      with_graph_lane_access (fun lane ->
          Timer.publish_if_running timer_state_port timer ~generation
            ~publish:(fun () ->
              publish_source_current source.source_value value;
              Var.queue_var lane source))

    let add_relative_deadline = Timer_policy.add_relative_deadline

    let add timestamp duration =
      add_relative_deadline timestamp (Duration.to_ms duration)

    let attach_timer ?(update_on_start = false) ?(refresh_when_inactive = true)
        ?refresh_operation ~runtime_contract signal interval update =
      let timer =
        Timer.create_daemon_node ~runtime_contract ~refresh_when_inactive
          ~refresh_operation
          (Timer.daemon_context
             ~advance_generation:(checked_succ "timer generation")
             ~state_access:
               (Timer.daemon_state_access ~with_state:(fun f ->
                    with_graph_lane_sync f))
             ~state:timer_state_port
             ~update:
               (Timer.daemon_update ~update:(fun timer ~generation ~missed ->
                    update.timer_update timer generation ~missed))
             ~hooks:
               (Timer.daemon_hooks
                 ~after_due_read_before_commit:(fun () ->
                   Effect.unit)
                 ~after_update_constructed_before_run:(fun () ->
                   Effect.unit)))
          ~interval_ms:(Duration.to_ms interval) ~update_on_start
          ~catch_up_policy:update.timer_catch_up_policy
      in
      signal.timer <- Some timer;
      signal

    let timer_refresh_operation source spec =
      Refresh_operation (source, spec)

    let make_timer_signal ?equal initial interval ~runtime_contract
        source_policy update =
      let source = Var.create ?equal initial in
      let signal = Var.watch source in
      Timer_policy.source_policy_result source_policy
        ~plan:
          (fun ~update_on_start ~catch_up_policy ~refresh_when_inactive
               ~refresh_on_demand ->
            let refresh_operation =
              Option.map (timer_refresh_operation source) refresh_on_demand
            in
            attach_timer ~update_on_start ~refresh_when_inactive
              ?refresh_operation ~runtime_contract signal interval
              {
                timer_catch_up_policy = catch_up_policy;
                timer_update =
                  (fun timer generation ~missed ->
                    update.source_timer_update timer generation ~missed source);
              })

    let construct_timer_signal f =
      with_graph_lane_sync (fun () ->
          try
            ignore
              (graph_result_or_raise (Graph.allocation_scope graph scope_ops));
            Ok (f ())
          with Graph_error err -> Error (err :> time_error))
      |> Effect.flatten_result

    let now ~every () =
      Effect.sync (fun () -> validate_interval every)
      |> Effect.flatten_result
      |> Effect.bind (fun () ->
             current_runtime_contract ()
             |> Effect.bind (fun runtime_contract ->
                    Effect.now
                    |> Effect.bind (fun initial ->
                           construct_timer_signal (fun () ->
                               make_timer_signal ~equal:Int.equal initial
                                 every ~runtime_contract
                                 (Timer_policy.current_time_source_policy ())
                                 {
                                   source_timer_update =
                                     (fun timer generation ~missed:_ source ->
                                       Effect.now
                                       |> Effect.bind (fun now_ms ->
                                              timer_set_source timer generation
                                                source now_ms
                                              |> Effect.map (fun _ -> ())));
                                 }))))

    let construct_deadline_signal every deadline_ms ~runtime_contract =
      construct_timer_signal (fun () ->
          make_timer_signal ~equal:Bool.equal false every ~runtime_contract
            (Timer_policy.deadline_source_policy ~deadline_ms)
            {
              source_timer_update =
                (fun timer generation ~missed:_ source ->
                  Effect.now
                  |> Effect.bind (fun now_ms ->
                         if now_ms >= deadline_ms then
                           timer_set_source timer generation source true
                           |> Effect.bind (function
                                | `Updated ->
                                    with_graph_lane_sync (fun () ->
                                        timer_finish_unlocked timer)
                                | `Stopped -> Effect.unit)
                         else
                           timer_set_source timer generation source false
                           |> Effect.map (fun _ -> ())));
            })

    let deadline ~every deadline =
      let deadline_ms = to_ms deadline in
      Effect.sync (fun () -> validate_interval every)
      |> Effect.flatten_result
      |> Effect.bind (fun () ->
             current_runtime_contract ()
             |> Effect.bind (fun runtime_contract ->
                    Effect.now
                    |> Effect.bind (fun now_ms ->
                           Effect.from_result
                             (validate_future now_ms deadline_ms)
                           |> Effect.bind (fun () ->
                                  construct_deadline_signal every deadline_ms
                                    ~runtime_contract))))

    let after ~every duration =
      Effect.sync (fun () ->
          match validate_interval every with
          | Error _ as error -> error
          | Ok () -> validate_positive_duration duration)
      |> Effect.flatten_result
      |> Effect.bind (fun () ->
             current_runtime_contract ()
             |> Effect.bind (fun runtime_contract ->
                    Effect.now
                    |> Effect.bind (fun now_ms ->
                           Effect.from_result
                             (add_relative_deadline now_ms
                                (Duration.to_ms duration))
                           |> Effect.bind (fun deadline_ms ->
                                  construct_deadline_signal every deadline_ms
                                    ~runtime_contract))))

    let interval interval =
      Effect.sync (fun () -> validate_interval interval)
      |> Effect.flatten_result
      |> Effect.bind (fun () ->
             current_runtime_contract ()
             |> Effect.bind (fun runtime_contract ->
                    construct_timer_signal (fun () ->
                        let interval_ms = Duration.to_ms interval in
                        make_timer_signal ~equal:Int.equal 0 interval
                          ~runtime_contract
                          (Timer_policy.interval_source_policy ~interval_ms)
                          {
                            source_timer_update =
                              (fun timer generation ~missed source ->
                                Effect.sync (fun () ->
                                    add_int_capped (Var.value source) missed)
                                |> Effect.annotate ~key:"eta_signal.timer.kind"
                                     ~value:"interval"
                                |> Effect.named "eta_signal.time.interval"
                                |> Effect.bind (fun next ->
                                       timer_set_source timer generation source
                                         next
                                       |> Effect.map (fun _ -> ())));
                          })))

    let step ~every ~initial f =
      Effect.sync (fun () -> validate_interval every)
      |> Effect.flatten_result
      |> Effect.bind (fun () ->
             current_runtime_contract ()
             |> Effect.bind (fun runtime_contract ->
                    construct_timer_signal (fun () ->
                        make_timer_signal initial every ~runtime_contract
                          (Timer_policy.step_source_policy ())
                          {
                            source_timer_update =
                              (fun timer generation ~missed source ->
                                timer_continue_after_update timer generation
                                |> Effect.bind (function
                                     | `Stop -> Effect.unit
                                     | `Continue ->
                                         Effect.sync (fun () ->
                                             f ~missed (Var.value source))
                                         |> Effect.annotate
                                              ~key:"eta_signal.timer.kind"
                                              ~value:"step"
                                         |> Effect.named "eta_signal.time.step"
                                         |> Effect.bind (fun next ->
                                                timer_set_source timer generation
                                                  source next
                                                |> Effect.map (fun _ -> ()))));
                          })))

    let step_replay ~every ~initial f =
      Effect.sync (fun () -> validate_interval every)
      |> Effect.flatten_result
      |> Effect.bind (fun () ->
             current_runtime_contract ()
             |> Effect.bind (fun runtime_contract ->
                    construct_timer_signal (fun () ->
                        make_timer_signal initial every ~runtime_contract
                          (Timer_policy.step_replay_source_policy ())
                          {
                            source_timer_update =
                              (fun timer generation ~missed:_ source ->
                                timer_continue_after_update timer generation
                                |> Effect.bind (function
                                     | `Stop -> Effect.unit
                                     | `Continue ->
                                         Effect.sync (fun () ->
                                             f (Var.value source))
                                         |> Effect.annotate
                                              ~key:"eta_signal.timer.kind"
                                              ~value:"step"
                                         |> Effect.named
                                              "eta_signal.time.step_replay"
                                         |> Effect.bind (fun next ->
                                                timer_set_source timer generation
                                                  source next
                                                |> Effect.map (fun _ -> ()))));
                          })))
  end

  module Stream = struct
    let default_capacity = Stream_bridge.default_capacity

    let observe ?(capacity = default_capacity) ?on_drop ?equal signal =
      Stream_bridge.observe ~capacity ?on_drop ?equal
        ~metrics:(graph_stream_bridge_metrics ())
        ~on_closed_with_error:(fun err ->
          Effect.sync (fun () -> raise (Graph_error err)))
        ~map_observe_error:(fun err -> (err :> stream_error))
        ~observe_delivery:
          (fun ?equal ~on_finish signal callback ->
            Observer.observe_delivery ?equal ~on_finish signal callback)
        signal

    let with_observed ?capacity ?on_drop ?equal signal f =
      Effect.with_resource
        ~acquire:(observe ?capacity ?on_drop ?equal signal)
        ~release:(fun (observer, _stream) ->
          Observer.dispose observer)
        (fun (_observer, stream) -> f stream)
  end
end

module Make_no_error () = Make (No_observer_error) ()
