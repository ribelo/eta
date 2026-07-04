module Effect = Eta.Effect
module Duration = Eta.Duration
module Queue = Eta.Queue
module Runtime_contract = Eta.Runtime_contract
module Bind = Eta_signal_bind
module Debug = Eta_signal_debug
module Error = Eta_signal_error
module Id = Eta_signal_id
module Kernel = Eta_signal_kernel
module Signal_snapshot = Kernel.Snapshot
module Lane = Eta_signal_lane
module Observer_core = Eta_signal_observer
module Observer_snapshot = Observer_core.Snapshot
module Observer_lifecycle = Observer_core.Lifecycle
module Scope = Eta_signal_scope
module Stabilization = Eta_signal_stabilization
module Stream_bridge = Eta_signal_stream_bridge
module Test_hooks = Eta_signal_test_hooks
module Timer = Eta_signal_timer
module Transaction = Eta_signal_transaction

module type Observer_error = sig
  type t

  val pp : Format.formatter -> t -> unit
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

  type weak_packed_signal = Kernel.Weak_cell.t

  type timer_catch_up_policy = Timer.catch_up_policy =
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

  and timer_state = Timer.state =
    | Timer_inactive of int
    | Timer_starting of int
    | Timer_running_uncancellable of int * int option
    | Timer_running of int * int option * (unit -> unit)
    | Timer_finished of int

  and timer_refresh_operation =
    | Refresh_operation : 'a var * 'a Timer.refresh_spec -> timer_refresh_operation

  and timer_transition =
    | Set_source : 'a var * 'a -> timer_transition
    | Advance_due of int
    | Finish of Timer.finish_plan

  and timer_node = {
    timer_snapshot : Timer.snapshot Transaction.staged;
    mutable timer_staged_refresh_token : int;
    timer_runtime_contract : Runtime_contract.t;
    timer_refresh_when_inactive : bool;
    timer_refresh_operation : timer_refresh_operation option;
    timer_start : 'err. timer_node -> (unit, 'err) Effect.t;
  }

  and 'err timer_start_attempt = {
    start_timer : timer_node;
    start_effect : (unit, 'err) Effect.t;
  }

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
    dead_timer : Timer.debug_snapshot option;
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

  module Kernel_edge_node = struct
    type id = signal_id
    type nonrec packed = packed_signal
    type t = Packed : 'a signal -> t

    let pack (Packed signal) = P signal
    let unpack (P signal) = Packed signal
    let id (Packed signal) = signal.id
    let equal_id left right = signal_id_int left = signal_id_int right
    let dependencies (Packed signal) = signal.dependencies
    let set_dependencies (Packed signal) dependencies =
      signal.dependencies <- dependencies
    let dependents (Packed signal) = signal.dependents
    let set_dependents (Packed signal) dependents =
      signal.dependents <- dependents
  end

  module Kernel_edges = Kernel.Make_edges (Kernel_edge_node)

  let kernel_edge_node signal = Kernel_edge_node.Packed signal

  module Kernel_dirty = Kernel.Make_dirty (struct
    type id = signal_id
    type nonrec packed = packed_signal

    let id (P signal) = signal.id
    let equal_id left right = signal_id_int left = signal_id_int right
    let dirty (P signal) = signal.dirty
    let set_dirty (P signal) dirty = signal.dirty <- dirty
  end)

  module Kernel_compute = Kernel.Make_compute (struct
    type nonrec packed = packed_signal
    type t = Kernel_edge_node.t

    let pack = Kernel_edge_node.pack
    let seen_generation (Kernel_edge_node.Packed signal) = signal.seen_generation

    let set_seen_generation (Kernel_edge_node.Packed signal) generation =
      signal.seen_generation <- generation

    let changed_seen (Kernel_edge_node.Packed signal) = signal.changed_seen

    let set_changed_seen (Kernel_edge_node.Packed signal) changed =
      signal.changed_seen <- changed

    let computing (Kernel_edge_node.Packed signal) = signal.computing

    let set_computing (Kernel_edge_node.Packed signal) computing =
      signal.computing <- computing

    let computed_generation (Kernel_edge_node.Packed signal) =
      signal.computed_generation

    let set_computed_generation (Kernel_edge_node.Packed signal) generation =
      signal.computed_generation <- generation
  end)

  module Private_test_hooks = struct
    type hook = Test_hooks.hook =
      | After_observer_delivery_claim
      | After_observer_activation_before_return
      | After_graph_lane_acquired
      | After_stream_try_send_before_ack
      | After_stream_drop_before_ack
      | After_timer_due_read_before_commit
      | After_timer_update_constructed_before_run

    type stats_count = Test_hooks.stats_count =
      | Stats_total_node_count
      | Stats_necessary_node_count
      | Stats_dead_node_count
      | Stats_lane_cancelled_waiter_count

    type action = Test_hooks.action = {
      run : 'err. unit -> (unit, 'err) Effect.t;
    }

    let state = Test_hooks.create ()
    let with_hook hook action f = Test_hooks.with_hook state hook action f
    let clear () = Test_hooks.clear state
    let run hook = Test_hooks.run state hook
    let note_lane_waiter_enqueued () =
      Test_hooks.note_lane_waiter_enqueued state

    let lane_waiter_enqueued_count () =
      Test_hooks.lane_waiter_enqueued_count state

    let note_lane_waiter_compaction () =
      Test_hooks.note_lane_waiter_compaction state

    let lane_waiter_compaction_count () =
      Test_hooks.lane_waiter_compaction_count state

    let set_stats_count_override count value =
      Test_hooks.set_stats_count_override state count value

    let stats_count_override count =
      Test_hooks.stats_count_override state count

    let set_timer_runtime_mismatch_hook hook =
      Test_hooks.set_timer_runtime_mismatch_hook state hook

    let run_timer_runtime_mismatch_hook () =
      Test_hooks.run_timer_runtime_mismatch_hook state

    type 'a observer_delivery_snapshot =
      | Test_delivery_never_delivered
      | Test_delivery_delivered of 'a
      | Test_delivery_pending of int * 'a update
      | Test_delivery_running of int * 'a update

    let active_live_state observer =
      match Observer_lifecycle.active_live observer.obs_state with
      | Some live -> live
      | None ->
          invalid_arg "Eta_signal.Private_test_hooks: observer is not active"

    let observer_current_snapshot live =
      Transaction.current live.observer_snapshot

    let set_observer_delivery observer delivery =
      let live = active_live_state observer in
      let snapshot = observer_current_snapshot live in
      let observer_delivery =
        match delivery with
        | Test_delivery_never_delivered -> Observer_never_delivered
        | Test_delivery_delivered value -> Observer_delivered value
        | Test_delivery_pending (token, update) ->
            Observer_delivery_pending (token, update, [])
        | Test_delivery_running (token, update) ->
            Observer_delivery_running (token, update, [])
      in
      Transaction.set_current live.observer_snapshot
        (Observer_snapshot.with_delivery snapshot observer_delivery)

    let observer_delivery observer =
      let live = active_live_state observer in
      match Observer_snapshot.delivery (observer_current_snapshot live) with
      | Observer_never_delivered -> Test_delivery_never_delivered
      | Observer_delivered value -> Test_delivery_delivered value
      | Observer_delivery_pending (token, update, _) ->
          Test_delivery_pending (token, update)
      | Observer_delivery_running (token, update, _) ->
          Test_delivery_running (token, update)

    let signal_version signal =
      Signal_snapshot.version (Transaction.current signal.snapshot)

    let set_signal_version signal value =
      let snapshot = Transaction.current signal.snapshot in
      Transaction.set_current signal.snapshot
        (Signal_snapshot.with_version snapshot value)
    let signal_valid signal = signal.valid
    let set_signal_valid signal value = signal.valid <- value

    let seed_var_source_value (type a) (signal : a signal) (value : a) =
      match signal.kind with
      | Var source ->
          Transaction.set_current source.source_value value;
          Transaction.set_current source.graph_value value
      | Const _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _ | Map6 _ | Map7 _
      | Map8 _ | Map9 _ | All _ | Bind _ ->
          invalid_arg
            "Eta_signal.Private_test_hooks: expected source-backed signal"

    let set_timer_generation signal generation =
      match signal.timer with
      | None ->
          invalid_arg "Eta_signal.Private_test_hooks: expected timer signal"
      | Some timer ->
          let snapshot = Transaction.current timer.timer_snapshot in
          Transaction.set_current timer.timer_snapshot
            (Timer.snapshot_with_generation snapshot generation)

    let set_timer_next_due signal next_due_ms =
      match signal.timer with
      | None ->
          invalid_arg "Eta_signal.Private_test_hooks: expected timer signal"
      | Some timer -> (
          let snapshot = Transaction.current timer.timer_snapshot in
          match Timer.snapshot_with_next_due snapshot next_due_ms with
          | Some snapshot ->
              Transaction.set_current timer.timer_snapshot
                snapshot
          | None ->
              invalid_arg
                "Eta_signal.Private_test_hooks: expected active timer state")

    let timer_state signal =
      match signal.timer with
      | None ->
          invalid_arg "Eta_signal.Private_test_hooks: expected timer signal"
      | Some timer ->
          Timer.state_label
            (Timer.snapshot_state
               (Transaction.current timer.timer_snapshot))

    let set_observer_on_finish observer hooks =
      let live =
        match Observer_lifecycle.live observer.obs_state with
        | Some live -> live
        | None ->
            invalid_arg
              "Eta_signal.Private_test_hooks: expected live observer state"
      in
      live.obs_on_finish <- hooks

    let run_observer_callback observer update =
      let live = active_live_state observer in
      let token =
        match
          Observer_core.Delivery.running_token
            (Observer_snapshot.delivery
               (observer_current_snapshot live))
        with
        | Some token -> token
        | None ->
            invalid_arg
              "Eta_signal.Private_test_hooks: observer delivery is not running"
      in
      observer.obs_callback token update
  end

  type disposal_hook = unit -> unit

  type event =
    | E : Observer_core.Delivery.token * 'a observer * 'a update -> event

  type pure_stabilize_result =
    | Pure_ok of
        disposal_hook list
        * event list
        * Stabilization.delivering Stabilization.token
    | Pure_graph_error of disposal_hook list * graph_error
    | Pure_defect of disposal_hook list * exn * Printexc.raw_backtrace

  type timer_refresh_context =
    (Runtime_contract.t, packed_signal * bool) Timer.refresh_context

  type graph = {
    lane : Lane.t;
    owner_domain : Domain.id;
    mutable next_id : int;
    mutable next_scope_id : int;
    stabilization : graph_error Stabilization.t;
    mutable stabilization_id : int;
    mutable pending_vars : packed_var list;
    mutable staged_binds : packed_bind list;
    mutable computed_nodes : packed_signal list;
    mutable pure_disposal_hooks : disposal_hook list;
    mutable timer_refresh_disposal_hooks : disposal_hook list;
    mutable timer_refresh_staged_timers : timer_node list;
    mutable observers : packed_observer list;
    mutable all_nodes : weak_packed_signal list;
    mutable dead_nodes : dead_signal list;
    current_scope : (scope_id, packed_signal, packed_signal) Scope.context;
    mutable pure_snapshot_commit_count : int;
    mutable callback_delivery_count : int;
    mutable recompute_count : int;
    mutable dynamic_scope_invalidations : int;
    mutable nodes_became_necessary : int;
    mutable nodes_became_unnecessary : int;
    mutable stream_bridge_metrics : Stream_bridge.metrics;
    mutable necessary_node_ids : (signal_id, unit) Hashtbl.t;
    mutable next_timer_refresh_token : int;
    mutable active_timer_refresh : timer_refresh_context option;
  }

  let graph =
    {
      lane =
        Lane.create ();
      owner_domain = Domain.self ();
      next_id = 0;
      next_scope_id = 1;
      stabilization = Stabilization.create ();
      stabilization_id = 0;
      pending_vars = [];
      staged_binds = [];
      computed_nodes = [];
      pure_disposal_hooks = [];
      timer_refresh_disposal_hooks = [];
      timer_refresh_staged_timers = [];
      observers = [];
      all_nodes = [];
      dead_nodes = [];
      current_scope = Scope.create_context ();
      pure_snapshot_commit_count = 0;
      callback_delivery_count = 0;
      recompute_count = 0;
      dynamic_scope_invalidations = 0;
      nodes_became_necessary = 0;
      nodes_became_unnecessary = 0;
      stream_bridge_metrics = Stream_bridge.create_metrics ();
      necessary_node_ids = Hashtbl.create 16;
      next_timer_refresh_token = 0;
      active_timer_refresh = None;
    }

  let pack_weak_signal signal = P signal
  let weak_packed_signal (P signal) = Kernel.Weak_cell.create signal
  let weak_packed_signal_value cell =
    Kernel.Weak_cell.value ~pack:pack_weak_signal cell

  let collect_live_weak_signals keep cells =
    Kernel.Weak_cell.collect ~pack:pack_weak_signal ~keep cells

  let all_nodes_unlocked () =
    let cells, nodes = collect_live_weak_signals (fun _ -> true) graph.all_nodes in
    graph.all_nodes <- cells;
    nodes

  let prune_all_nodes_unlocked () =
    ignore (all_nodes_unlocked () : packed_signal list)

  let children_with_scope_owner signal children =
    Scope.children_with_scope_owner
      ~owner_valid:(fun (P owner) -> owner.valid)
      ~owner_node:(fun owner -> owner)
      signal.scope children

  module Kernel_reachable_static = Kernel.Make_reachable (struct
    type id = signal_id
    type nonrec packed = packed_signal

    let id (P signal) = signal.id
    let valid (P signal) = signal.valid

    let children (P signal) =
      children_with_scope_owner signal signal.dependencies
  end)

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

  let graph_context_error_message =
    "Eta_signal: signal graph APIs must be called on the domain that created "
    ^ "the graph and not from runtime worker callbacks"

  let ensure_graph_context () =
    if
      Domain.self () <> graph.owner_domain
      || Runtime_contract.in_registered_worker_context ()
    then invalid_arg graph_context_error_message

  let graph_lane_depth_local : int Runtime_contract.local =
    Runtime_contract.create_local ()

  let with_graph_lane_sync f =
    Lane.with_sync ~leaf_name:"Eta_signal.with_graph_lane_sync"
      ~depth_local:graph_lane_depth_local ~ensure_context:ensure_graph_context
      ~hooks:
        {
          note_waiter_enqueued = Private_test_hooks.note_lane_waiter_enqueued;
          note_waiter_compaction =
            Private_test_hooks.note_lane_waiter_compaction;
        }
      ~after_acquired:(fun () ->
        Private_test_hooks.run After_graph_lane_acquired)
      graph.lane f

  (* Synchronous constructors mutate graph indexes without entering the graph
     lane. Keep this path same-domain, non-effectful, and callback-free;
     effectful public operations must use [with_graph_lane_sync]. *)
  let next_id () =
    ensure_graph_context ();
    let id = graph.next_id in
    graph.next_id <- checked_succ "node id" id;
    id

  let next_signal_id () = Id.signal (next_id ())
  let next_var_id () = Id.var (next_id ())
  let next_observer_id () = Id.observer (next_id ())

  let new_scope owner =
    let id = graph.next_scope_id in
    graph.next_scope_id <- checked_succ "scope id" id;
    Scope.create ~id:(Id.scope id) ~owner:(P owner) ~parent:owner.scope

  let current_generation () = graph.stabilization_id

  let remove_dependent child parent =
    Kernel_edges.remove_dependent ~child:(kernel_edge_node child)
      ~parent:(kernel_edge_node parent)

  let detach_dependency parent child =
    Kernel_edges.detach_dependency ~parent:(kernel_edge_node parent)
      ~child:(kernel_edge_node child)

  let has_dependency parent child =
    Kernel_edges.has_dependency ~parent:(kernel_edge_node parent)
      ~child:(kernel_edge_node child)

  let has_dependent child parent =
    Kernel_edges.has_dependent ~child:(kernel_edge_node child)
      ~parent:(kernel_edge_node parent)

  let attach_dependency parent child =
    Kernel_edges.attach_dependency ~parent:(kernel_edge_node parent)
      ~child:(kernel_edge_node child)

  let attach_packed_dependency parent child =
    Kernel_edges.attach_packed_dependency ~parent:(kernel_edge_node parent) child

  let mark_self_dirty packed =
    Kernel_dirty.mark packed

  let mark_timer_refresh_dirty packed =
    match graph.active_timer_refresh with
    | None -> Kernel_dirty.mark packed
    | Some context ->
        Timer.set_refresh_dirty_items context
          (Kernel_dirty.mark_recording_previous
             (Timer.refresh_dirty_items context)
             packed)

  let remove_var_watcher source signal =
    source.watchers <-
      List.filter
        (fun cell ->
          match weak_packed_signal_value cell with
          | None -> false
          | Some (P candidate) -> candidate.valid && candidate.id <> signal.id)
        source.watchers

  let active_transaction () =
    Stabilization.active_transaction graph.stabilization

  let stage_var_graph_value (type a) (var : a var) value =
    Transaction.stage (active_transaction ()) var.graph_value value

  let stage_var_source_value (type a) (var : a var) value =
    Transaction.stage (active_transaction ()) var.source_value value

  let effective_var_value (type a) (var : a var) =
    match Stabilization.transaction graph.stabilization with
    | Some transaction -> Transaction.read transaction var.graph_value
    | None -> Transaction.current var.graph_value

  let remember_computed (P signal) =
    let generation = current_generation () in
    graph.computed_nodes <-
      Kernel_compute.remember ~generation graph.computed_nodes
        (kernel_edge_node signal)

  let signal_current_snapshot signal =
    Transaction.current signal.snapshot

  let signal_effective_snapshot signal =
    match Stabilization.transaction graph.stabilization with
    | Some transaction -> Transaction.read transaction signal.snapshot
    | None -> signal_current_snapshot signal

  let update_signal_staging signal f =
    let transaction = active_transaction () in
    let snapshot = Transaction.read transaction signal.snapshot in
    Transaction.stage transaction signal.snapshot (f snapshot)

  let signal_staged_in_active_transaction signal =
    match Stabilization.transaction graph.stabilization with
    | Some transaction -> Transaction.staged transaction signal.snapshot
    | None -> false

  let discard_signal_staging signal =
    match Stabilization.transaction graph.stabilization with
    | Some transaction -> Transaction.discard transaction signal.snapshot
    | None -> ()

  let stage_signal signal value =
    update_signal_staging signal (fun snapshot ->
        let current = signal_current_snapshot signal in
        Signal_snapshot.publish
          ~advance_version:(checked_succ "signal version")
          ~current snapshot value)

  let effective_signal_version signal =
    Signal_snapshot.version (signal_effective_snapshot signal)

  module Kernel_versions = Kernel.Make_versions (struct
    type id = signal_id
    type nonrec packed = packed_signal

    let id (P signal) = signal.id
    let equal_id left right = signal_id_int left = signal_id_int right
    let version (P signal) = effective_signal_version signal
  end)

  let dependency_versions dependencies =
    Kernel_versions.snapshot dependencies

  let dependencies_changed signal dependencies =
    Kernel_versions.changed
      ~current:
        (Signal_snapshot.dependency_versions
           (signal_current_snapshot signal))
      dependencies

  let stage_dependency_versions signal dependencies =
    update_signal_staging signal (fun snapshot ->
        Signal_snapshot.with_dependency_versions snapshot
          (dependency_versions dependencies))

  let effective_signal_value signal =
    match Signal_snapshot.value (signal_effective_snapshot signal) with
    | Some value -> value
    | None -> raise (Graph_error `Invalid_scope)

  let observer_live_state observer =
    Observer_lifecycle.live observer.obs_state

  let observer_active_live_state observer =
    Observer_lifecycle.active_live observer.obs_state

  let live_state_or_invalid_arg observer operation =
    match observer_live_state observer with
    | Some live -> live
    | None ->
        invalid_arg
          ("Eta_signal: cannot " ^ operation
         ^ " a disposed or invalid observer")

  let observer_current_snapshot live =
    Transaction.current live.observer_snapshot

  let observer_effective_snapshot live =
    match Stabilization.transaction graph.stabilization with
    | Some transaction -> Transaction.read transaction live.observer_snapshot
    | None -> observer_current_snapshot live

  let update_observer_staging live f =
    let transaction = active_transaction () in
    let snapshot = Transaction.read transaction live.observer_snapshot in
    Transaction.stage transaction live.observer_snapshot (f snapshot)

  let set_observer_current live snapshot =
    Transaction.set_current live.observer_snapshot snapshot

  let set_observer_current_delivery live observer_delivery =
    let snapshot = observer_current_snapshot live in
    set_observer_current live
      (Observer_snapshot.with_delivery snapshot observer_delivery)

  let observer_active (O observer) =
    Observer_lifecycle.active observer.obs_state

  let observer_demands_signal (O observer) =
    Observer_lifecycle.demands observer.obs_state

  let observer_roots selected observers =
    List.filter_map
      (fun (O observer as packed) ->
        if selected packed then Some (P observer.obs_signal) else None)
      observers

  let observer_demand_roots observers =
    observer_roots observer_demands_signal observers

  let observer_active_roots observers =
    observer_roots observer_active observers

  let remove_observer observer =
    graph.observers <-
      List.filter
        (fun (O candidate) -> candidate.obs_id <> observer.obs_id)
        graph.observers

  let observer_finish_hooks live reason =
    List.map (fun hook () -> hook reason) live.obs_on_finish

  let observer_value_of_live live =
    Observer_snapshot.value (observer_current_snapshot live)

  let finish_observer_unlocked observer reason =
    let finish =
      Observer_lifecycle.finish ~value_of_live:observer_value_of_live reason
        observer.obs_state
    in
    observer.obs_state <- finish.state;
    if finish.remove then remove_observer observer;
    match finish.hook_live with
    | None -> []
    | Some live -> observer_finish_hooks live reason

  let dispose_observer_unlocked observer =
    finish_observer_unlocked observer Observer_lifecycle.Finish_disposed

  let invalidate_observer_unlocked observer =
    finish_observer_unlocked observer Observer_lifecycle.Finish_invalid_scope

  let dispose_signal_observers signal =
    let observers =
      List.filter
        (fun (O observer) -> observer.obs_signal.id = signal.id)
        graph.observers
    in
    List.concat_map
      (fun (O observer) -> invalidate_observer_unlocked observer)
      observers

  let signal_scope () =
    match Stabilization.state graph.stabilization with
    | Idle -> Scope.current graph.current_scope
    | Pure -> (
        match Scope.require_valid_current graph.current_scope with
        | Ok scope -> Some scope
        | Error `Ambiguous_scope -> raise (Graph_error `Ambiguous_scope))
    | Committed | Delivering -> raise (Graph_error `Ambiguous_scope)

  let add_to_scope scope signal =
    match scope with
    | None -> ()
    | Some scope -> Scope.add_node scope (P signal)

  let validate_dependency (P signal) =
    if not signal.valid then raise (Graph_error `Invalid_scope)

  let timer_state_generation = Timer.state_generation

  let timer_current_snapshot timer =
    Transaction.current timer.timer_snapshot

  let timer_effective_snapshot timer =
    match Stabilization.transaction graph.stabilization with
    | Some transaction -> Transaction.read transaction timer.timer_snapshot
    | None -> timer_current_snapshot timer

  let set_timer_current_snapshot timer snapshot =
    Transaction.set_current timer.timer_snapshot snapshot

  let set_timer_current_state timer timer_state =
    let snapshot = timer_current_snapshot timer in
    set_timer_current_snapshot timer
      (Timer.snapshot_with_state snapshot timer_state)

  let update_timer_staging timer f =
    let transaction = active_transaction () in
    let snapshot = Transaction.read transaction timer.timer_snapshot in
    Transaction.stage transaction timer.timer_snapshot (f snapshot)

  let timer_current_state timer =
    Timer.snapshot_state (timer_current_snapshot timer)

  let timer_generation timer =
    timer_state_generation (timer_current_state timer)

  let timer_state_label = Timer.state_label

  let timer_has_staged_refresh timer =
    match graph.active_timer_refresh with
    | Some context ->
        timer.timer_staged_refresh_token = Timer.refresh_token context
    | None -> false

  let timer_effective_state timer =
    if timer_has_staged_refresh timer then
      Timer.snapshot_state (timer_effective_snapshot timer)
    else timer_current_state timer

  let timer_active_state = Timer.state_active

  let timer_active timer = timer_active_state (timer_effective_state timer)

  let timer_finished_state = Timer.state_finished

  let timer_finished timer = timer_finished_state (timer_effective_state timer)

  let timer_needs_start timer =
    Timer.needs_start ~effective_state:(timer_effective_state timer)
      ~current_state:(timer_current_state timer)

  let ensure_timer_runtime timer runtime_contract =
    if
      not
        (Runtime_contract.same_runtime timer.timer_runtime_contract runtime_contract)
    then (
      Private_test_hooks.run_timer_runtime_mismatch_hook ();
      raise (Graph_error `Runtime_mismatch))

  let timer_can_refresh_on_demand token timer =
    Timer.can_refresh_on_demand
      ~refresh_operation:(Option.is_some timer.timer_refresh_operation)
      ~current_token:
        (Timer.snapshot_on_demand_refresh_token
           (timer_current_snapshot timer))
      ~staged_token:timer.timer_staged_refresh_token ~token
      ~refresh_when_inactive:timer.timer_refresh_when_inactive
      ~active:(timer_active timer) ~finished:(timer_finished timer)

  let timer_running_generation timer =
    Timer.state_running_generation (timer_effective_state timer)

  let timer_has_cancel timer =
    Timer.state_has_cancel (timer_effective_state timer)

  let add_int_capped = Timer.add_int_capped

  let timer_set_next_due_state = Timer.state_set_next_due

  let remember_timer_refresh_timer timer =
    match graph.active_timer_refresh with
    | None -> ()
    | Some context ->
        let timer_refresh_token = Timer.refresh_token context in
        if timer.timer_staged_refresh_token <> timer_refresh_token then (
          timer.timer_staged_refresh_token <- timer_refresh_token;
          update_timer_staging timer (fun snapshot ->
              Timer.snapshot_with_on_demand_refresh_token snapshot
                timer_refresh_token);
          graph.timer_refresh_staged_timers <-
            timer :: graph.timer_refresh_staged_timers)

  let stage_timer_state_unlocked timer state =
    remember_timer_refresh_timer timer;
    update_timer_staging timer (fun snapshot ->
        Timer.snapshot_with_state snapshot state)

  let timer_apply_stop_plan_unlocked timer plan =
    set_timer_current_state timer plan.Timer.stop_state;
    plan.Timer.stop_cancel_hooks

  let timer_mark_unneeded_unlocked ?(cancel_running = true) timer =
    match
      Timer.stop
        ~advance_generation:(checked_succ "timer generation")
        ~cancel_running (timer_current_state timer)
    with
    | None -> []
    | Some plan -> timer_apply_stop_plan_unlocked timer plan

  let timer_rollback_unclaimed_start_unlocked timer =
    match timer_current_state timer with
    | Timer_starting _ -> timer_mark_unneeded_unlocked timer
    | Timer_inactive _ | Timer_running_uncancellable _ | Timer_running _
    | Timer_finished _ ->
        []

  let new_signal ?(dirty = true) ?equal kind dependencies =
    ensure_graph_context ();
    List.iter validate_dependency dependencies;
    let scope = signal_scope () in
    let signal =
      {
        id = next_signal_id ();
        equal = Option.value equal ~default:default_equal;
        kind;
        snapshot =
          Transaction.create_staged Signal_snapshot.empty;
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
      }
    in
    List.iter (attach_packed_dependency signal) dependencies;
    add_to_scope scope signal;
    graph.all_nodes <- weak_packed_signal (P signal) :: graph.all_nodes;
    signal

  let new_const ?equal value =
    let signal = new_signal ?equal ~dirty:false (Const value) [] in
    Transaction.set_current signal.snapshot
      (Signal_snapshot.initialized value);
    signal

  let prune_invalid_nodes_unlocked () =
    let cells, _ =
      collect_live_weak_signals (fun (P signal) -> signal.valid) graph.all_nodes
    in
    graph.all_nodes <- cells

  let max_dead_signal_tombstones = 1024

  let timer_debug_snapshot timer =
    let snapshot = Timer.debug_snapshot (timer_effective_state timer) in
    { snapshot with debug_generation = timer_generation timer }

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

  let record_dead_node_unlocked (P signal as packed) =
    graph.dead_nodes <-
      Debug.remember_latest ~max_count:max_dead_signal_tombstones
        ~id:(fun tombstone -> tombstone.dead_id)
        ~equal_id:(fun left right -> signal_id_int left = signal_id_int right)
        (signal_tombstone packed) graph.dead_nodes

  let rec invalidate_scope ?(prune = true) scope =
    match Scope.invalidate scope with
    | None -> []
    | Some nodes ->
        graph.dynamic_scope_invalidations <-
          saturating_succ graph.dynamic_scope_invalidations;
        let hooks = List.concat_map invalidate_node nodes in
        if prune then prune_invalid_nodes_unlocked ();
        hooks

  and invalidate_node (P signal) =
    if signal.valid then (
      let dependencies = signal.dependencies in
      let dependents = signal.dependents in
      let timer_hooks =
        match signal.timer with
        | None -> []
        | Some timer -> timer_mark_unneeded_unlocked timer
      in
      signal.valid <- false;
      record_dead_node_unlocked (P signal);
      let observer_hooks = dispose_signal_observers signal in
      List.iter
        (fun (P dependency) -> remove_dependent dependency signal)
        dependencies;
      signal.dependencies <- [];
      signal.dependents <- [];
      let dependent_hooks = List.concat_map invalidate_node dependents in
      let kind_hooks =
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
            []
      in
      timer_hooks @ observer_hooks @ dependent_hooks @ kind_hooks)
    else []

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

  let prepare_signal_commit (P signal) =
    if (not signal.valid) && signal_staged_in_active_transaction signal then
      discard_signal_staging signal

  let commit_signal (P signal) =
    if signal.valid then signal.dirty <- false

  let commit_transaction () =
    match Stabilization.commit_transaction graph.stabilization with
    | Ok () -> ()
    | Error err -> raise (Graph_error err)

  let rollback_transaction () =
    Stabilization.rollback_transaction graph.stabilization

  let remember_staged_bind (B bind as packed) =
    let transaction = active_transaction () in
    if not (Transaction.staged transaction bind.snapshot) then
      graph.staged_binds <- packed :: graph.staged_binds

  let stage_bind_switch bind source_value inner scope =
    remember_staged_bind (B bind);
    Transaction.stage (active_transaction ()) bind.snapshot
      (Bind.switch ~source_value ~inner ~scope)

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
    match Stabilization.transaction graph.stabilization with
    | Some transaction -> Transaction.read transaction bind.snapshot
    | None -> bind_current_snapshot bind

  let bind_effective_inner bind =
    Bind.inner (bind_effective_snapshot bind)

  let bind_staged_snapshot (type a b) (bind : (a, b) bind) :
      (a, b signal, scope) Bind.snapshot option =
    let transaction = active_transaction () in
    if Transaction.staged transaction bind.snapshot then
      Some (Transaction.read transaction bind.snapshot)
    else None

  let commit_bind (B bind) =
    match (bind.owner, bind_staged_snapshot bind) with
    | Some owner, Some staged -> (
        let current = bind_current_snapshot bind in
        match Bind.commit_switch ~current ~staged with
        | Ok plan ->
            Option.iter (detach_dependency owner) plan.old_inner;
            let hooks =
              Option.fold ~none:[] ~some:invalidate_scope plan.old_scope
            in
            attach_dependency owner plan.new_inner;
            hooks
        | Error `Invalid_scope -> raise (Graph_error `Invalid_scope))
    | _, None -> []
    | _ -> raise (Graph_error `Invalid_scope)

  let rollback_bind (B bind) =
    match bind_staged_snapshot bind with
    | Some staged -> (
        match Bind.rollback_switch ~staged with
        | Ok scope -> invalidate_scope scope
        | Error `Invalid_scope -> raise (Graph_error `Invalid_scope))
    | None -> []

  let collect_scope_invalidations_into ?exclude_signal_id seen collected scope =
    Scope_invalidation.collect ?exclude_node_id:exclude_signal_id seen
      collected scope

  let preflight_timer_invalidation timer =
    Timer.preflight_stop
      ~advance_generation:(checked_succ "timer generation")
      ~effective_state:(timer_effective_state timer)
      ~current_state:(timer_current_state timer)

  let preflight_timer_start timer =
    Timer.preflight_start
      ~advance_generation:(checked_succ "timer generation")
      ~effective_state:(timer_effective_state timer)
      ~current_state:(timer_current_state timer)

  let preflight_staged_bind_commit seen collected (B bind) =
    match (bind.owner, bind_staged_snapshot bind) with
    | Some owner, Some staged -> (
        let current = bind_current_snapshot bind in
        match Bind.preflight_switch ~current ~staged with
        | Ok old_scope ->
            Option.iter
              (collect_scope_invalidations_into ~exclude_signal_id:owner.id seen
                 collected)
              old_scope
        | Error `Invalid_scope -> raise (Graph_error `Invalid_scope))
    | _, None -> ()
    | _ -> raise (Graph_error `Invalid_scope)

  let preflight_signal_commit invalidated_ids (P signal) =
    if
      signal.valid
      && not (Hashtbl.mem invalidated_ids signal.id)
      && signal_staged_in_active_transaction signal
    then
      let current = signal_current_snapshot signal in
      let staged = signal_effective_snapshot signal in
      Signal_snapshot.preflight_commit_version
        ~advance_version:(checked_succ "signal version")
        ~current ~staged

  let collect_staged_bind_invalidations () =
    let invalidated_ids = Hashtbl.create 16 in
    let invalidated_nodes = ref [] in
    List.iter
      (preflight_staged_bind_commit invalidated_ids invalidated_nodes)
      graph.staged_binds;
    (invalidated_ids, !invalidated_nodes)

  let collect_post_commit_necessary_timers invalidated_ids =
    prune_all_nodes_unlocked ();
    let module Reachable = Kernel.Make_reachable (struct
      type id = signal_id
      type nonrec packed = packed_signal

      let id (P signal) = signal.id

      let valid (P signal) =
        signal.valid && not (Hashtbl.mem invalidated_ids signal.id)

      let children (P signal) =
        let signal_children =
          match signal.kind with
          | Bind bind ->
              Bind.dependencies ~source:(P bind.source)
                ~inner:
                  (Option.map (fun inner -> P inner)
                     (bind_effective_inner bind))
          | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _
          | Map6 _ | Map7 _ | Map8 _ | Map9 _ | All _ ->
              signal.dependencies
        in
        children_with_scope_owner signal signal_children
    end)
    in
    Reachable.fold ~roots:(observer_demand_roots graph.observers)
      ~init:(Hashtbl.create 8)
      ~f:(fun timers (P signal) ->
        Option.iter (fun timer -> Hashtbl.replace timers signal.id timer)
          signal.timer;
        timers)

  let preflight_post_commit_timer_starts invalidated_ids =
    collect_post_commit_necessary_timers invalidated_ids
    |> Hashtbl.iter (fun _ timer -> preflight_timer_start timer)

  let preflight_commit_staging () =
    let invalidated_ids, invalidated_nodes =
      collect_staged_bind_invalidations ()
    in
    List.iter
      (fun (P signal) -> Option.iter preflight_timer_invalidation signal.timer)
      invalidated_nodes;
    List.iter (preflight_signal_commit invalidated_ids) graph.computed_nodes;
    preflight_post_commit_timer_starts invalidated_ids

  let remember_pure_disposal_hooks hooks =
    graph.pure_disposal_hooks <- hooks @ graph.pure_disposal_hooks

  let remember_timer_refresh_disposal_hooks hooks =
    if Option.is_some graph.active_timer_refresh then
      graph.timer_refresh_disposal_hooks <-
        hooks @ graph.timer_refresh_disposal_hooks
    else remember_pure_disposal_hooks hooks

  let queue_var_unlocked (type a) (source : a var) =
    if not source.queued then (
      source.queued <- true;
      graph.pending_vars <- V source :: graph.pending_vars)

  let set_var_source_unlocked (type a) (source : a var) value =
    Transaction.set_current source.source_value value;
    queue_var_unlocked source

  let stage_timer_source_value (type a) (source : a var) value =
    let graph_value = effective_var_value source in
    stage_var_source_value source value;
    if not (source.var_equal graph_value value) then (
      stage_var_graph_value source value;
      List.iter mark_timer_refresh_dirty (source_watchers_unlocked source))

  let timer_finish_plan state =
    Timer.finish
      ~advance_generation:(checked_succ "timer generation")
      state

  let timer_finish_unlocked timer =
    let plan = timer_finish_plan (timer_current_state timer) in
    set_timer_current_state timer plan.finish_state

  let timer_finish_cancel_hooks_unlocked timer =
    let plan = timer_finish_plan (timer_current_state timer) in
    set_timer_current_state timer plan.finish_state;
    plan.finish_cancel_hooks

  let stage_timer_transition timer = function
    | Set_source (source, value) ->
        stage_timer_source_value source value
    | Advance_due next_due_ms ->
        stage_timer_state_unlocked timer
          (timer_set_next_due_state (timer_effective_state timer)
             (Some next_due_ms))
    | Finish plan ->
        stage_timer_state_unlocked timer plan.finish_state;
        remember_timer_refresh_disposal_hooks plan.finish_cancel_hooks

  let timer_refresh_action source = function
    | Timer.Refresh_set value -> Set_source (source, value)
    | Timer.Refresh_advance_due next_due_ms -> Advance_due next_due_ms
    | Timer.Refresh_finish plan -> Finish plan

  let timer_refresh_plan timer now_ms (Refresh_operation (source, spec)) =
    Timer.refresh_actions_for_spec
      ~advance_generation:(checked_succ "timer generation")
      ~state:(timer_effective_state timer)
      ~current_value:(effective_var_value source) ~now_ms spec
    |> List.map (timer_refresh_action source)

  let stage_timer_refresh_operation timer now_ms operation =
    List.iter
      (stage_timer_transition timer)
      (timer_refresh_plan timer now_ms operation)

  let clear_timer_refresh_timer_staging timer =
    timer.timer_staged_refresh_token <- -1

  let rollback_timer_refresh_dirty_nodes () =
    match graph.active_timer_refresh with
    | None -> ()
    | Some context ->
        Kernel_dirty.restore (Timer.refresh_dirty_items context);
        Timer.clear_refresh_dirty_items context

  let commit_timer_refresh_staging timer =
    clear_timer_refresh_timer_staging timer

  let clear_timer_refresh_staging () =
    rollback_timer_refresh_dirty_nodes ();
    List.iter clear_timer_refresh_timer_staging graph.timer_refresh_staged_timers;
    graph.timer_refresh_staged_timers <- [];
    graph.timer_refresh_disposal_hooks <- []

  let reset_staging () =
    let disposal_hooks =
      List.concat_map rollback_bind graph.staged_binds @ graph.pure_disposal_hooks
    in
    rollback_transaction ();
    graph.computed_nodes <- [];
    graph.staged_binds <- [];
    graph.pure_disposal_hooks <- [];
    clear_timer_refresh_staging ();
    disposal_hooks

  let commit_staging () =
    preflight_commit_staging ();
    let commit_hooks = List.concat_map commit_bind graph.staged_binds in
    remember_pure_disposal_hooks commit_hooks;
    List.iter prepare_signal_commit graph.computed_nodes;
    commit_transaction ();
    List.iter commit_timer_refresh_staging graph.timer_refresh_staged_timers;
    List.iter commit_signal graph.computed_nodes;
    let disposal_hooks =
      graph.pure_disposal_hooks @ graph.timer_refresh_disposal_hooks
    in
    graph.computed_nodes <- [];
    graph.staged_binds <- [];
    graph.pure_disposal_hooks <- [];
    graph.timer_refresh_disposal_hooks <- [];
    graph.timer_refresh_staged_timers <- [];
    graph.pure_snapshot_commit_count <-
      saturating_succ graph.pure_snapshot_commit_count;
    disposal_hooks

  let requeue_if_needed (V var as packed) =
    if not var.queued then (
      var.queued <- true;
      graph.pending_vars <- packed :: graph.pending_vars)

  let mark_failed_without_current (O observer) =
    match observer_active_live_state observer with
    | Some live ->
        let snapshot = observer_current_snapshot live in
        set_observer_current live
          (Observer_snapshot.with_value snapshot
             (Observer_core.Value.mark_failed_without_current
                (Observer_snapshot.value snapshot)))
    | None -> ()

  let rollback_pure pure_token observers pending_at_start =
    let disposal_hooks = reset_staging () in
    List.iter mark_failed_without_current observers;
    List.iter requeue_if_needed pending_at_start;
    graph.active_timer_refresh <- None;
    ignore
      (Stabilization.rollback_to_idle graph.stabilization pure_token
        : Stabilization.idle Stabilization.token);
    disposal_hooks

  let next_timer_refresh_token_unlocked () =
    let token = graph.next_timer_refresh_token in
    graph.next_timer_refresh_token <-
      checked_succ "timer refresh token" graph.next_timer_refresh_token;
    token

  let stage_pending_var (V var) =
    let graph_value = Transaction.current var.graph_value in
    let source_value = Transaction.current var.source_value in
    if not (var.var_equal graph_value source_value) then (
      stage_var_graph_value var source_value;
      List.iter mark_self_dirty (source_watchers_unlocked var))

  let refresh_timer_source_for_compute signal =
    match (graph.active_timer_refresh, signal.timer) with
    | Some timer_refresh, Some timer ->
        let timer_refresh_token = Timer.refresh_token timer_refresh in
        ensure_timer_runtime timer
          (Timer.refresh_runtime_contract timer_refresh);
        if timer_can_refresh_on_demand timer_refresh_token timer then (
          remember_timer_refresh_timer timer;
          let now_ms = Timer.refresh_sample_now_ms timer_refresh in
          match timer.timer_refresh_operation with
          | None -> ()
          | Some operation -> stage_timer_refresh_operation timer now_ms operation)
    | None, _ | Some _, None -> ()

  let rec compute : type a. a signal -> a * bool =
   fun signal ->
    if not signal.valid then raise (Graph_error `Invalid_scope);
    refresh_timer_source_for_compute signal;
    let generation = current_generation () in
    let compute_node = kernel_edge_node signal in
    if Kernel_compute.seen ~generation compute_node then
      (effective_signal_value signal, Kernel_compute.changed_seen compute_node)
    else
      Kernel_compute.run ~generation compute_node
        ~cycle:(fun () -> raise (Graph_error `Cycle))
        ~compute:(fun () -> compute_uncached signal)

  and compute_uncached : type a. a signal -> a * bool =
   fun signal ->
    remember_computed (P signal);
    let signal_initialized () =
      Signal_snapshot.is_initialized (signal_effective_snapshot signal)
    in
    let recompute value =
      graph.recompute_count <- saturating_succ graph.recompute_count;
      let snapshot = signal_effective_snapshot signal in
      let changed =
        Kernel.Value_cutoff.changed ~equal:signal.equal
          ~initialized:(Signal_snapshot.is_initialized snapshot)
          ~current:(Signal_snapshot.value snapshot) ~next:value
      in
      if changed then stage_signal signal value;
      (if changed then value else current_or_raise signal), changed
    in
    let use_cached () = (current_or_raise signal, false) in
    let dependency_changed dependencies =
      dependencies_changed signal dependencies
    in
    let recompute_with_dependencies dependencies value =
      stage_dependency_versions signal dependencies;
      recompute value
    in
    let static_child child_signal =
      Kernel.Static_eval.child ~dependency:(P child_signal)
        (compute child_signal)
    in
    let finish_static ?(stage_dependencies = true) result =
      match
        Kernel.Static_eval.plan ~stage_dependencies ~dirty:signal.dirty
          ~initialized:(signal_initialized ())
          ~dependencies_changed:dependency_changed result
      with
      | Kernel.Static_eval.Use_cached -> use_cached ()
      | Kernel.Static_eval.Recompute
          { dependencies; output; stage_dependencies } ->
          if stage_dependencies then recompute_with_dependencies dependencies output
          else recompute output
    in
    match signal.kind with
    | Const value ->
        finish_static ~stage_dependencies:false (Kernel.Static_eval.leaf value)
    | Var var ->
        finish_static ~stage_dependencies:false
          (Kernel.Static_eval.leaf (effective_var_value var))
    | Map (a, f) ->
        let a_child = static_child a in
        finish_static (Kernel.Static_eval.map a_child f)
    | Map2 (a, b, f) ->
        let a_child = static_child a in
        let b_child = static_child b in
        finish_static
          (Kernel.Static_eval.map2 a_child b_child f)
    | Map3 (a, b, c, f) ->
        let a_child = static_child a in
        let b_child = static_child b in
        let c_child = static_child c in
        finish_static
          (Kernel.Static_eval.map3 a_child b_child c_child f)
    | Map4 (a, b, c, d, f) ->
        let a_child = static_child a in
        let b_child = static_child b in
        let c_child = static_child c in
        let d_child = static_child d in
        finish_static
          (Kernel.Static_eval.map4 a_child b_child c_child d_child f)
    | Map5 (a, b, c, d, e, f) ->
        let a_child = static_child a in
        let b_child = static_child b in
        let c_child = static_child c in
        let d_child = static_child d in
        let e_child = static_child e in
        finish_static
          (Kernel.Static_eval.map5 a_child b_child c_child d_child e_child f)
    | Map6 (a, b, c, d, e, f_signal, f) ->
        let a_child = static_child a in
        let b_child = static_child b in
        let c_child = static_child c in
        let d_child = static_child d in
        let e_child = static_child e in
        let f_child = static_child f_signal in
        finish_static
          (Kernel.Static_eval.map6 a_child b_child c_child d_child e_child
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
          (Kernel.Static_eval.map7 a_child b_child c_child d_child e_child
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
          (Kernel.Static_eval.map8 a_child b_child c_child d_child e_child
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
          (Kernel.Static_eval.map9 a_child b_child c_child d_child e_child
             f_child g_child h_child i_child f)
    | All signals ->
        let children =
          List.fold_right
            (fun child_signal children ->
              static_child child_signal :: children)
            signals []
        in
        finish_static (Kernel.Static_eval.all children)
    | Bind bind ->
        let source_value, source_changed = compute bind.source in
        (match
           Bind.eval_plan ~equal:bind.source.equal
             (bind_effective_snapshot bind) ~source_value
         with
        | Error `Invalid_scope -> raise (Graph_error `Invalid_scope)
        | Ok Bind.Switch -> (
          let scope = new_scope signal in
          let eval =
            match
              Bind.eval_switch ~scope ~source_value
                ~selector:bind.selector
                ~with_scope:(fun scope f ->
                  Scope.with_current graph.current_scope scope f)
                ~validate_inner:(fun scope inner ->
                  Scope_validation.validate_inner ~scope (P inner))
                ~compute_inner:compute
                ~on_failure:(fun scope ->
                  remember_pure_disposal_hooks (invalidate_scope scope))
            with
            | Ok eval -> eval
            | Error `Invalid_scope -> raise (Graph_error `Invalid_scope)
          in
          let inner = eval.Bind.eval_inner in
          let inner_value = eval.Bind.eval_value in
          let dependencies =
            Bind.dependencies ~source:(P bind.source) ~inner:(Some (P inner))
          in
          graph.recompute_count <- saturating_succ graph.recompute_count;
          let snapshot = signal_effective_snapshot signal in
          let changed =
            Kernel.Value_cutoff.changed ~equal:signal.equal
              ~initialized:(Signal_snapshot.is_initialized snapshot)
              ~current:(Signal_snapshot.value snapshot) ~next:inner_value
          in
          stage_bind_switch bind source_value inner scope;
          stage_dependency_versions signal dependencies;
          if changed then stage_signal signal inner_value;
          (if changed then inner_value else current_or_raise signal), changed)
        | Ok (Bind.Reuse inner) ->
          (match
             Bind.eval_reuse ~source_dependency:(P bind.source)
               ~inner_dependency:(P inner) ~source_changed
               ~compute_inner:(fun () -> compute inner) ~dirty:signal.dirty
               ~initialized:(signal_initialized ())
               ~dependencies_changed:dependency_changed
           with
          | Bind.Reuse_recompute { reuse_dependencies; reuse_value } ->
              recompute_with_dependencies reuse_dependencies reuse_value
          | Bind.Reuse_cached -> use_cached ()))

  let timer_apply_start_plan_unlocked timer plan =
    set_timer_current_state timer plan.Timer.start_state;
    { start_timer = timer; start_effect = timer.timer_start timer }

  let timer_begin_start timer generation =
    with_graph_lane_sync (fun () ->
        match Timer.begin_start (timer_current_state timer) ~generation with
        | Some state ->
            set_timer_current_state timer state;
            `Continue
        | None -> `Stop)

  let collect_necessary_node_ids () =
    prune_all_nodes_unlocked ();
    Kernel_reachable_static.ids ~roots:(observer_demand_roots graph.observers)

  let update_necessity_counters_unlocked () =
    let next = collect_necessary_node_ids () in
    Hashtbl.iter
      (fun id () ->
        if not (Hashtbl.mem graph.necessary_node_ids id) then
          graph.nodes_became_necessary <-
            saturating_succ graph.nodes_became_necessary)
      next;
    Hashtbl.iter
      (fun id () ->
        if not (Hashtbl.mem next id) then
          graph.nodes_became_unnecessary <-
            saturating_succ graph.nodes_became_unnecessary)
      graph.necessary_node_ids;
    graph.necessary_node_ids <- next

  let necessary_timers () =
    prune_all_nodes_unlocked ();
    Kernel_reachable_static.fold
      ~roots:(observer_demand_roots graph.observers)
      ~init:(Hashtbl.create 8)
      ~f:(fun timers (P signal) ->
        Option.iter (fun timer -> Hashtbl.replace timers signal.id timer)
          signal.timer;
        timers)

  let all_timers () =
    List.filter_map
      (fun (P signal) -> Option.map (fun timer -> (signal.id, timer)) signal.timer)
      (all_nodes_unlocked ())

  let fail_disposal_hooks causes =
    let cause =
      match causes with
      | [] -> invalid_arg "Eta_signal.fail_disposal_hooks: empty causes"
      | [ cause ] -> cause
      | causes -> Eta.Cause.sequential causes
    in
    Effect.Expert.make ~leaf_name:"Eta_signal.run_disposal_hooks" (fun _ ->
        Eta.Exit.Error cause)

  let run_disposal_hooks hooks =
    let rec loop failures = function
      | [] -> (
          match List.rev failures with
          | [] -> Effect.unit
          | causes -> fail_disposal_hooks causes)
      | hook :: rest ->
          Effect.exit (Effect.sync hook)
          |> Effect.bind (function
               | Eta.Exit.Ok () -> loop failures rest
               | Eta.Exit.Error cause -> loop (cause :: failures) rest)
    in
    loop [] hooks

  let run_disposal_hooks_as_finalizers hooks =
    Effect.unit |> Effect.on_exit (fun _exit -> run_disposal_hooks hooks)

  let run_pending_disposal_hooks_as_finalizers hooks_ref =
    match !hooks_ref with
    | [] -> Effect.unit
    | hooks ->
        run_disposal_hooks_as_finalizers hooks
        |> Effect.on_exit (fun _exit ->
               Effect.sync (fun () -> hooks_ref := []))

  let fail_with_pending_disposal_hooks hooks_ref eff =
    eff
    |> Effect.on_exit (fun _exit ->
           run_pending_disposal_hooks_as_finalizers hooks_ref)

  let graph_error_with_pending_disposal_hooks hooks_ref err =
    fail_with_pending_disposal_hooks hooks_ref
      (Effect.fail (err :> stabilize_error))

  let run_pending_timer_cancel_hooks hooks_ref =
    match !hooks_ref with
    | [] -> Effect.unit
    | hooks ->
        (run_disposal_hooks hooks
         |> Effect.on_exit (fun _exit ->
                Effect.sync (fun () -> hooks_ref := [])))
        |> Effect.uninterruptible

  let refresh_timer_demand_unlocked runtime_contract =
    let needed = necessary_timers () in
    let demand_items =
      all_timers ()
      |> List.map (fun (id, timer) ->
             let necessary = Hashtbl.mem needed id in
             if necessary then ensure_timer_runtime timer runtime_contract;
             {
               Timer.demand_item = timer;
               demand_necessary = necessary;
               demand_effective_state = timer_effective_state timer;
               demand_current_state = timer_current_state timer;
             })
    in
    let timer_plans =
      Timer.demand_plans
        ~advance_generation:(checked_succ "timer generation")
        ~cancel_running:true demand_items
    in
    let start_attempts = ref [] in
    let cancel_hooks = ref [] in
    List.iter
      (function
        | Timer.Demand_plan_start (timer, plan) ->
            start_attempts :=
              timer_apply_start_plan_unlocked timer plan :: !start_attempts
        | Timer.Demand_plan_stop (timer, Some plan) ->
            cancel_hooks :=
              List.rev_append
                (timer_apply_stop_plan_unlocked timer plan)
                !cancel_hooks
        | Timer.Demand_plan_stop (_, None) -> ())
      timer_plans;
    (List.rev !start_attempts, List.rev !cancel_hooks)

  let rollback_unclaimed_timer_starts attempts =
    with_graph_lane_sync (fun () ->
        List.concat_map
          (fun attempt ->
            timer_rollback_unclaimed_start_unlocked attempt.start_timer)
          attempts)
    |> Effect.bind run_disposal_hooks

  let run_timer_start_attempts attempts =
    Effect.concat (List.map (fun attempt -> attempt.start_effect) attempts)

  let current_runtime_contract () =
    Effect.Expert.make ~leaf_name:"Eta_signal.current_runtime_contract"
      (fun context -> Eta.Exit.Ok (Effect.Expert.contract context))

  let refresh_timer_demand () =
    current_runtime_contract ()
    |> Effect.bind (fun runtime_contract ->
           Effect.acquire_use_release
             ~acquire:
               (with_graph_lane_sync (fun () ->
                    try
                      let start_attempts, cancel_hooks =
                        refresh_timer_demand_unlocked runtime_contract
                      in
                      Ok (start_attempts, ref cancel_hooks)
                    with Graph_error err -> Error err)
                |> Effect.flatten_result)
             ~release:(fun (start_attempts, cancel_hooks_ref) ->
               rollback_unclaimed_timer_starts start_attempts
               |> Effect.bind (fun () ->
                      run_pending_timer_cancel_hooks cancel_hooks_ref))
             (fun (start_attempts, cancel_hooks_ref) ->
               run_pending_timer_cancel_hooks cancel_hooks_ref
               |> Effect.bind (fun () -> run_timer_start_attempts start_attempts)))

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
                     run_pending_disposal_hooks_as_finalizers hooks_ref)))
      |> Effect.uninterruptible
    else run_pending_disposal_hooks_as_finalizers hooks_ref

  let pending_disposal_hooks hooks_ref =
    match !hooks_ref with
    | [] -> false
    | _ :: _ -> true

  let run_pending_dispose_cleanup hooks_ref refresh_timers =
    if !refresh_timers || pending_disposal_hooks hooks_ref then
      ((if !refresh_timers then
          Effect.sync (fun () -> refresh_timers := false)
          |> Effect.bind (fun () ->
                 refresh_timer_demand ()
                 |> Effect.or_die (fun err -> Graph_error err))
        else Effect.unit)
       |> Effect.bind (fun () ->
              run_pending_disposal_hooks_as_finalizers hooks_ref))
      |> Effect.uninterruptible
    else Effect.unit

  let run_pending_dispose_checked_cleanup hooks_ref refresh_timers =
    if !refresh_timers || pending_disposal_hooks hooks_ref then
      ((if !refresh_timers then
          Effect.sync (fun () -> refresh_timers := false)
          |> Effect.bind (fun () -> refresh_timer_demand ())
        else Effect.unit)
       |> Effect.bind (fun () ->
              run_pending_disposal_hooks_as_finalizers hooks_ref))
      |> Effect.uninterruptible
    else Effect.unit

  let run_pending_registration_abort_cleanup hooks_ref refresh_timers =
    let best_effort eff = Effect.exit eff |> Effect.map (fun _ -> ()) in
    if !refresh_timers || pending_disposal_hooks hooks_ref then
      ((if !refresh_timers then
          Effect.sync (fun () -> refresh_timers := false)
          |> Effect.bind (fun () -> refresh_timer_demand ())
          |> Effect.ignore_errors
          |> best_effort
        else Effect.unit)
       |> Effect.bind (fun () ->
              run_pending_disposal_hooks_as_finalizers hooks_ref
              |> best_effort))
      |> Effect.uninterruptible
    else Effect.unit

  let dispose_observer_with_cleanup cleanup observer =
    let hooks_ref = ref [] in
    let refresh_timers = ref false in
    with_graph_lane_sync
      (fun () ->
        (match observer.obs_state with
         | Observer_lifecycle.Disposed _ -> ()
         | Observer_lifecycle.Registering _ | Observer_lifecycle.Active _
         | Observer_lifecycle.Invalid_scope _ ->
          let hooks = dispose_observer_unlocked observer in
          hooks_ref := hooks;
          refresh_timers := true;
          update_necessity_counters_unlocked ()))
    |> Effect.bind (fun () ->
           cleanup hooks_ref refresh_timers)
    |> Effect.on_exit (fun _exit ->
           cleanup hooks_ref refresh_timers)

  let dispose_observer_effect observer =
    dispose_observer_with_cleanup run_pending_dispose_cleanup observer

  let dispose_observer_checked_effect observer =
    dispose_observer_with_cleanup run_pending_dispose_checked_cleanup observer

  let abort_observer_registration_effect observer =
    let hooks_ref = ref [] in
    let refresh_timers = ref false in
    let run_cleanup () =
      run_pending_registration_abort_cleanup hooks_ref refresh_timers
    in
    with_graph_lane_sync
      (fun () ->
        match observer.obs_state with
        | Observer_lifecycle.Registering _ | Observer_lifecycle.Active _
        | Observer_lifecycle.Invalid_scope _ ->
            let hooks = dispose_observer_unlocked observer in
            hooks_ref := hooks;
            refresh_timers := true;
            update_necessity_counters_unlocked ();
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
          ~inner:(Option.map (fun inner -> P inner) (bind_effective_inner bind))
    | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _ | Map6 _
    | Map7 _ | Map8 _ | Map9 _ | All _ ->
        signal.dependencies

  module Kernel_signal_order = Kernel.Make_order (struct
    type id = signal_id
    type t = packed_signal

    let id (P signal) = signal.id

    let equal_id left right =
      Int.equal (signal_id_int left) (signal_id_int right)

    let compare_id left right =
      Int.compare (signal_id_int left) (signal_id_int right)

    let children (P signal) = observer_order_dependencies signal
  end)

  let compare_observer_graph_order (O left) (O right) =
    let signal_order =
      Kernel_signal_order.compare (P left.obs_signal) (P right.obs_signal)
    in
    if signal_order = 0 then compare_observer_id left.obs_id right.obs_id
    else signal_order

  let collect_observed_bind_nodes observers =
    prune_all_nodes_unlocked ();
    Kernel_reachable_static.fold ~roots:(observer_active_roots observers) ~init:[]
      ~f:(fun binds (P signal as packed) ->
        match signal.kind with
        | Bind _ -> packed :: binds
        | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _
        | Map6 _ | Map7 _ | Map8 _ | Map9 _ | All _ ->
            binds)
    |> List.sort compare_signal_scope_then_id

  let signal_will_be_invalidated_by_staged_bind (P signal) =
    let invalidated_ids, _ = collect_staged_bind_invalidations () in
    Hashtbl.mem invalidated_ids signal.id

  let plan_staged_bind_switches observers =
    List.iter
      (fun (P signal as packed) ->
        if
          signal.valid
          && not (signal_will_be_invalidated_by_staged_bind packed)
        then
          match signal.kind with
          | Bind _ -> ignore (compute signal : _ * bool)
          | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _
          | Map6 _ | Map7 _ | Map8 _ | Map9 _ | All _ ->
              ())
      (collect_observed_bind_nodes observers)

  let collect_observer_event (O observer) =
    match observer_active_live_state observer with
    | None -> None
    | Some live
      when signal_will_be_invalidated_by_staged_bind (P observer.obs_signal) ->
        None
    | Some live ->
      let value, changed = compute observer.obs_signal in
      let snapshot = observer_effective_snapshot live in
      let event_plan =
        Observer_snapshot.plan_event ~equal:observer.obs_equal ~changed
          ~value snapshot
      in
      Transaction.stage (active_transaction ()) live.observer_snapshot
        event_plan.snapshot;
      Option.map
        (fun update -> E (current_generation (), observer, update))
        event_plan.update

  let mark_event_pending (E (token, observer, update)) =
    match observer_active_live_state observer with
    | Some live ->
        set_observer_current live
          (Observer_snapshot.with_pending_delivery ~token update
             (observer_current_snapshot live))
    | None -> ()

  let run_after_ack_actions_unlocked actions =
    List.iter (fun action -> action ()) actions

  let acknowledge_event_delivery observer token update =
    with_graph_lane_sync (fun () ->
        match observer_active_live_state observer with
        | None -> ()
        | Some live -> (
        let snapshot = observer_current_snapshot live in
        match
          Observer_snapshot.acknowledge_delivery ~token ~update
            ~after_ack:[] snapshot
        with
        | Some (snapshot, after_ack) ->
            set_observer_current live snapshot;
            run_after_ack_actions_unlocked after_ack
        | None -> ()))

  let claim_event_delivery observer token =
    with_graph_lane_sync (fun () ->
        match observer_active_live_state observer with
        | None -> false
        | Some live -> (
        let snapshot = observer_current_snapshot live in
        match Observer_snapshot.claim_delivery ~token snapshot with
        | Some snapshot ->
            set_observer_current live snapshot;
            true
        | None -> false))

  let release_event_delivery_claim observer token =
    with_graph_lane_sync (fun () ->
        match observer_active_live_state observer with
        | None -> ()
        | Some live -> (
        let snapshot = observer_current_snapshot live in
        match Observer_snapshot.release_delivery ~token snapshot with
        | Some snapshot ->
            set_observer_current live snapshot
        | None -> ()))

  let finish_event_delivery_after_error observer token update ~delivered =
    with_graph_lane_sync (fun () ->
        match observer_active_live_state observer with
        | None -> ()
        | Some live -> (
            let snapshot = observer_current_snapshot live in
            match
              Observer_snapshot.finish_running_delivery ~token ~update
                ~delivered ~after_ack:[] snapshot
            with
            | Some
                (Observer_snapshot.Finish_acknowledged
                  (snapshot, after_ack)) ->
                set_observer_current live snapshot;
                run_after_ack_actions_unlocked after_ack
            | Some (Observer_snapshot.Finish_released snapshot) ->
                set_observer_current live snapshot
            | None -> ()))

  let claimed_event_delivery_active observer token =
    match Observer_lifecycle.active_live observer.obs_state with
    | Some live ->
        Observer_snapshot.running_delivery_token_matches ~token
          (observer_current_snapshot live)
    | None -> false

  let acknowledge_stream_published_delivery observer token update ~after_ack =
    with_graph_lane_sync (fun () ->
        match observer_active_live_state observer with
        | None -> ()
        | Some live -> (
        let snapshot = observer_current_snapshot live in
        match
          Observer_snapshot.acknowledge_delivery ~token ~update
            ~after_ack snapshot
        with
        | Some (snapshot, after_ack) ->
            set_observer_current live snapshot;
            run_after_ack_actions_unlocked after_ack
        | None -> ()))

  let acknowledge_stream_sent_delivery observer token update =
    acknowledge_stream_published_delivery observer token update ~after_ack:[]

  let acknowledge_stream_drop_delivery observer token update ~after_ack =
    acknowledge_stream_published_delivery observer token update ~after_ack

  let active_event_delivery_token observer token =
    with_graph_lane_sync (fun () ->
        if claimed_event_delivery_active observer token then Some token
        else None)

  let begin_stabilize timer_refresh =
    match Stabilization.begin_pure graph.stabilization with
    | Error `Reentrant_stabilization ->
        Pure_graph_error ([], `Reentrant_stabilization)
    | Ok pure_token ->
      let generation =
        checked_succ "stabilization generation" graph.stabilization_id
      in
      graph.stabilization_id <- generation;
      graph.computed_nodes <- [];
      graph.staged_binds <- [];
      graph.pure_disposal_hooks <- [];
      graph.timer_refresh_disposal_hooks <- [];
      graph.timer_refresh_staged_timers <- [];
      graph.active_timer_refresh <- timer_refresh;
      let pending_at_start = List.rev graph.pending_vars in
      graph.pending_vars <- [];
      List.iter (fun (V var) -> var.queued <- false) pending_at_start;
      let observers =
        graph.observers |> List.filter observer_active
      in
      try
        List.iter stage_pending_var pending_at_start;
        plan_staged_bind_switches observers;
        let delivery_observers =
          List.sort compare_observer_graph_order observers
        in
        let events = List.filter_map collect_observer_event delivery_observers in
        let hooks = commit_staging () in
        List.iter mark_event_pending events;
        update_necessity_counters_unlocked ();
        graph.active_timer_refresh <- None;
        let delivering_token =
          Stabilization.commit_to_delivering graph.stabilization
            pure_token
        in
        Pure_ok (hooks, events, delivering_token)
      with
      | Graph_error err ->
          let hooks = rollback_pure pure_token observers pending_at_start in
          Pure_graph_error (hooks, err)
      | exn ->
          let backtrace = Printexc.get_raw_backtrace () in
          let hooks = rollback_pure pure_token observers pending_at_start in
          Pure_defect (hooks, exn, backtrace)

  let finish_stabilize delivering_token =
    graph.active_timer_refresh <- None;
    ignore
      (Stabilization.finish_delivering graph.stabilization
         delivering_token
        : Stabilization.idle Stabilization.token)

  let graph_error_of_die die =
    match die.Eta.Cause.exn with
    | Graph_error err -> Some err
    | _ -> None

  let run_observer_effect observer token update observer_eff =
    let delivered = ref false in
    let finish_delivery_after_error () =
      finish_event_delivery_after_error observer token update
        ~delivered:!delivered
    in
    ((Effect.Expert.make ~leaf_name:"eta_signal.observer" @@ fun context ->
      try
        if not (claimed_event_delivery_active observer token) then Eta.Exit.Ok ()
        else
          match Effect.Expert.eval context observer_eff with
          | Eta.Exit.Ok () ->
              delivered := true;
              Eta.Exit.Ok ()
          | Eta.Exit.Error cause ->
              Eta.Exit.Error
                (Error.observer_cause_to_stabilize ~graph_error_of_die cause)
      with
      | Graph_error err ->
          Eta.Exit.Error (Eta.Cause.Fail (err :> stabilize_error)))
     |> Effect.bind (fun () -> acknowledge_event_delivery observer token update))
    |> Effect.on_exit (function
         | Eta.Exit.Ok _ -> Effect.unit
         | Eta.Exit.Error _ -> finish_delivery_after_error ())

  let mark_callback_delivery_complete () =
    with_graph_lane_sync (fun () ->
        graph.callback_delivery_count <-
          saturating_succ graph.callback_delivery_count)

  let event_observer_active observer =
    with_graph_lane_sync (fun () -> observer_active (O observer))

  let construct_observer_effect observer token update =
    Effect.sync (fun () ->
        try
          if claimed_event_delivery_active observer token then
            Ok (Some (observer.obs_callback token update))
          else Ok None
        with Graph_error err -> Error (err :> stabilize_error))
    |> Effect.flatten_result

  let rec run_events = function
    | [] -> Effect.unit
    | E (token, observer, update) :: rest -> (
        event_observer_active observer
        |> Effect.bind (function
             | false -> run_events rest
             | true ->
                 claim_event_delivery observer token
                 |> Effect.bind (function
                      | false -> run_events rest
                      | true ->
                          (Private_test_hooks.run After_observer_delivery_claim
                           |> Effect.bind (fun () ->
                                  construct_observer_effect observer token update)
                           |> Effect.bind (function
                                | None -> Effect.unit
                                | Some observer_eff ->
                                    run_observer_effect observer token update
                                      observer_eff))
                          |> Effect.on_exit (function
                               | Eta.Exit.Ok _ -> Effect.unit
                               | Eta.Exit.Error _ ->
                                   release_event_delivery_claim observer token)
                          |> Effect.bind (fun () -> run_events rest))))

  let begin_stabilize_with_pending_hooks timer_refresh hooks_ref
      finish_token_ref =
    let result = begin_stabilize timer_refresh in
    let hooks =
      match result with
      | Pure_ok (hooks, _, _) | Pure_graph_error (hooks, _)
      | Pure_defect (hooks, _, _) ->
          hooks
    in
    hooks_ref := hooks;
    (match result with
     | Pure_ok (_, _, delivering_token) ->
         finish_token_ref := Some delivering_token
     | Pure_graph_error _ | Pure_defect _ -> ());
    result

  let finish_stabilize_with_pending_cleanup hooks_ref refresh_timers
      finish_token_ref =
    run_pending_stabilize_cleanup hooks_ref refresh_timers
    |> Effect.on_exit (fun _exit ->
           match !finish_token_ref with
           | None -> Effect.unit
           | Some delivering_token ->
               with_graph_lane_sync (fun () ->
                   finish_stabilize delivering_token))

  let stabilize =
    Effect.sync (fun () -> (ref [], ref false, ref None))
    |> Effect.bind
         (fun (hooks_ref, refresh_timers, finish_token_ref) ->
           current_runtime_contract ()
           |> Effect.bind (fun runtime_contract ->
                  with_graph_lane_sync (fun () ->
                      try
                        let timer_refresh =
                          Some
                            (Timer.create_refresh_context
                               ~token:(next_timer_refresh_token_unlocked ())
                               ~runtime_contract
                               ~now_ms:runtime_contract.Runtime_contract.now_ms)
                        in
                        begin_stabilize_with_pending_hooks timer_refresh
                          hooks_ref finish_token_ref
                      with Graph_error err -> Pure_graph_error ([], err))
                  |> Effect.bind (function
                       | Pure_graph_error (_, err) ->
                           graph_error_with_pending_disposal_hooks hooks_ref err
                       | Pure_defect (_, exn, backtrace) ->
                           defect_with_pending_disposal_hooks hooks_ref exn
                             backtrace
                       | Pure_ok (_, events, _) ->
                           refresh_timers := true;
                           run_pending_stabilize_cleanup hooks_ref refresh_timers
                           |> Effect.bind (fun () -> run_events events)
                           |> Effect.bind mark_callback_delivery_complete))
           |> Effect.on_exit (fun _exit ->
                  finish_stabilize_with_pending_cleanup hooks_ref refresh_timers
                    finish_token_ref))

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
      if Stabilization.is_pure graph.stabilization then
        raise (Graph_error `Ambiguous_scope);
      Transaction.current source.source_value

    let watch (source : 'a t) =
      let signal = new_signal (Var source) [] in
      source.watchers <- weak_packed_signal (P signal) :: source.watchers;
      signal

    let queue_var (source : 'a t) = queue_var_unlocked source

    let set_unlocked (source : 'a t) value =
      set_var_source_unlocked source value

    let set (source : 'a t) value =
      with_graph_lane_sync (fun () ->
          if source.updating then Error `Reentrant_update
          else (
            set_unlocked source value;
            Ok ()))
      |> Effect.flatten_result

    let set_from_update (source : 'a t) value =
      with_graph_lane_sync (fun () ->
          set_unlocked source value;
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

    type 'a delivery = {
      token : delivery_token;
      update : 'a update;
      current_token :
        'err. unit -> (delivery_token option, 'err) Effect.t;
      acknowledge_sent :
        'err. delivery_token -> 'a update -> (unit, 'err) Effect.t;
      acknowledge_drop :
        'err.
        after_ack:observer_after_ack_action list ->
        delivery_token ->
        'a update ->
        (unit, 'err) Effect.t;
    }

    let delivery observer token update =
      {
        token;
        update;
        current_token = (fun () -> active_event_delivery_token observer token);
        acknowledge_sent =
          (fun token update ->
            acknowledge_stream_sent_delivery observer token update);
        acknowledge_drop =
          (fun ~after_ack token update ->
            acknowledge_stream_drop_delivery observer token update ~after_ack);
      }

    let transfer_active_observer observer =
      (* This is deliberately a same-domain leaf, not another lane acquisition:
         the transfer check must not introduce a new lane-release callback
         window between the final state check and returning the handle. *)
      Effect.sync (fun () ->
          ensure_graph_context ();
          match Observer_lifecycle.activate observer.obs_state with
          | Ok state ->
              observer.obs_state <- state;
              Ok observer
          | Error `Invalid_scope -> Error `Invalid_scope)
      |> Effect.flatten_result

    let observe_with_hooks_delivery_callback ?(equal = default_equal)
        ?(on_finish = []) signal callback =
      with_graph_lane_sync (fun () ->
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
              graph.observers <- O observer :: graph.observers;
              update_necessity_counters_unlocked ();
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
    let dispose_checked observer = dispose_observer_checked_effect observer
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

  let active_observer_count () =
    List.fold_left
      (fun count observer ->
        if observer_active observer then saturating_succ count else count)
      0 graph.observers

  let invalid_observer_count () =
    List.fold_left
      (fun count (O observer) ->
        if Observer_lifecycle.invalid_scope observer.obs_state then
          saturating_succ count
        else count)
      0 graph.observers

  let necessary_node_count () =
    Hashtbl.length (collect_necessary_node_ids ())

  let dead_node_count () = List.length graph.dead_nodes

  let live_dirty_node_count all_nodes =
    List.fold_left
      (fun count (P signal) ->
        if signal.valid && signal.dirty then saturating_succ count else count)
      0 all_nodes

  let stats_counter name value =
    match Debug.stats_counter ~name value with
    | Ok value -> value
    | Error (`Counter_overflow name) -> counter_overflow name

  let stats_count count actual =
    Option.value (Private_test_hooks.stats_count_override count) ~default:actual

  let stats () =
    with_graph_lane_sync (fun () ->
        try
          let all_nodes = all_nodes_unlocked () in
          Ok
            {
              pure_snapshot_commit_count =
                stats_counter "stats pure_snapshot_commit_count"
                  graph.pure_snapshot_commit_count;
              callback_delivery_count =
                stats_counter "stats callback_delivery_count"
                  graph.callback_delivery_count;
              total_node_count =
                stats_counter "stats total_node_count"
                  (stats_count Private_test_hooks.Stats_total_node_count
                     (List.length all_nodes));
              active_observer_count =
                stats_counter "stats active_observer_count"
                  (active_observer_count ());
              invalid_observer_count =
                stats_counter "stats invalid_observer_count"
                  (invalid_observer_count ());
              necessary_node_count =
                stats_counter "stats necessary_node_count"
                  (stats_count Private_test_hooks.Stats_necessary_node_count
                     (necessary_node_count ()));
              dead_node_count =
                stats_counter "stats dead_node_count"
                  (stats_count Private_test_hooks.Stats_dead_node_count
                     (dead_node_count ()));
              live_dirty_node_count =
                stats_counter "stats live_dirty_node_count"
                  (live_dirty_node_count all_nodes);
              recompute_count =
                stats_counter "stats recompute_count" graph.recompute_count;
              dynamic_scope_invalidations =
                stats_counter "stats dynamic_scope_invalidations"
                  graph.dynamic_scope_invalidations;
              nodes_became_necessary =
                stats_counter "stats nodes_became_necessary"
                  graph.nodes_became_necessary;
              nodes_became_unnecessary =
                stats_counter "stats nodes_became_unnecessary"
                  graph.nodes_became_unnecessary;
              stream_bridge_drop_count =
                stats_counter "stats stream_bridge_drop_count"
                  (Stream_bridge.drop_count graph.stream_bridge_metrics);
              lane_waiter_count =
                stats_counter "stats lane_waiter_count"
                  (Lane.waiting_count graph.lane);
              lane_cancelled_waiter_count =
                stats_counter "stats lane_cancelled_waiter_count"
                  (stats_count
                     Private_test_hooks.Stats_lane_cancelled_waiter_count
                     (Lane.cancelled_count graph.lane));
            }
        with Graph_error err -> Error err)
    |> Effect.flatten_result

  let signal_selected :
      type a. dot_options -> (signal_id, unit) Hashtbl.t -> a signal -> bool =
   fun options necessary signal ->
    match options.dot_scope with
    | `Necessary -> Hashtbl.mem necessary signal.id
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

  let debug_timer_snapshot (timer : Timer.debug_snapshot) =
    {
      Debug.timer_active = timer.debug_active;
      timer_running_generation = timer.debug_running_generation;
      timer_has_cancel = timer.debug_has_cancel;
      timer_finished = timer.debug_finished;
      timer_generation = timer.debug_generation;
    }

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
    with_graph_lane_sync @@ fun () ->
    let necessary = collect_necessary_node_ids () in
    let all_nodes = all_nodes_unlocked () in
    let selected signal = signal_selected options necessary signal in
    let include_dead_nodes =
      match options.dot_scope with
      | `All_including_invalid -> true
      | `Necessary | `All_valid -> false
    in
    let live_ids = Hashtbl.create 16 in
    let dead_ids = Hashtbl.create 16 in
    if include_dead_nodes then
      List.iter
        (fun tombstone -> Hashtbl.replace dead_ids tombstone.dead_id ())
        graph.dead_nodes;
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
        List.map
          (fun tombstone ->
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
          graph.dead_nodes
      else []
    in
    let dot_observers =
      if options.dot_observers then
        graph.observers
        |> List.filter_map (fun (O observer as packed) ->
               if observer_selected ~include_invalid:include_dead_nodes packed
               then
                 let observed_signal_selected =
                   selected_id observer.obs_signal.id
                 in
                 let missing_observed_signal_id =
                   if include_dead_nodes && not observed_signal_selected then
                     Some observer.obs_signal.id
                   else None
                 in
                 Some
                   {
                     Debug.dot_observer_id =
                       observer_id_label observer.obs_id;
                     dot_observer_label =
                       observer_label ?missing_observed_signal_id packed;
                     dot_observed_signal_id =
                       (if observed_signal_selected then
                          Some (dot_signal_id observer.obs_signal.id)
                        else None);
                   }
               else None)
      else []
    in
    Debug.render_dot ~nodes:(live_dot_nodes @ dead_dot_nodes)
      ~observers:dot_observers

  module Time = struct
    exception Timer_cancelled

    let validate_interval duration =
      Timer.validate_interval_ms (Duration.to_ms duration)

    let validate_future now deadline_ms =
      Timer.validate_future_deadline ~now_ms:now ~deadline_ms

    let validate_positive_duration duration =
      Timer.validate_positive_duration_ms (Duration.to_ms duration)

    let install_timer_cancel timer generation cancel =
      with_graph_lane_sync (fun () ->
          match
            Timer.install_cancel (timer_current_state timer) ~generation
              ~cancel
          with
          | Some state ->
              set_timer_current_state timer state;
              `Continue
          | None -> `Stop)

    let cancellable_timer_loop timer generation loop =
      Effect.Expert.make ~leaf_name:"eta_signal.timer" @@ fun context ->
      let contract = Effect.Expert.contract context in
      let cancelled_exit = function
        | Eta.Exit.Error cause when Eta.Cause.is_interrupt_only cause ->
            Eta.Exit.Ok ()
        | exit -> exit
      in
      try
        contract.Runtime_contract.cancel_sub @@ fun cancel_context ->
        let cancel () =
          contract.Runtime_contract.cancel cancel_context Timer_cancelled
        in
        match
          Effect.Expert.eval context
            (install_timer_cancel timer generation cancel)
        with
        | Eta.Exit.Error _ as error -> error
        | Eta.Exit.Ok `Stop -> Eta.Exit.Ok ()
        | Eta.Exit.Ok `Continue ->
            Effect.Expert.eval context loop |> cancelled_exit
      with exn ->
        if Option.is_some (contract.Runtime_contract.cancellation_reason exn)
        then Eta.Exit.Ok ()
        else Effect.Expert.exit_of_exn context exn

    let timer_daemon_exit = function
      | Eta.Exit.Ok _ -> Timer.Daemon_ok
      | Eta.Exit.Error _ -> Timer.Daemon_error

    let apply_timer_cleanup timer generation cleanup exit =
      let daemon_exit = timer_daemon_exit exit in
      with_graph_lane_sync (fun () ->
          Option.iter (set_timer_current_state timer)
            (cleanup
               ~advance_generation:(checked_succ "timer generation")
               ~effective_state:(timer_effective_state timer)
               ~current_state:(timer_current_state timer) ~generation
               daemon_exit))

    let timer_cleanup_after_exit timer generation exit =
      apply_timer_cleanup timer generation Timer.cleanup_after_exit exit

    let timer_cleanup_failed_start timer generation exit =
      apply_timer_cleanup timer generation Timer.cleanup_failed_start exit

    let timer_after_update_state timer generation =
      with_graph_lane_sync (fun () ->
          match Timer.daemon_status (timer_effective_state timer) ~generation with
          | Timer.Daemon_continue -> `Continue
          | Timer.Daemon_stop -> `Stop)

    let timer_set_source timer generation (source : 'a var) value =
      with_graph_lane_sync (fun () ->
          match Timer.daemon_status (timer_effective_state timer) ~generation with
          | Timer.Daemon_continue ->
            Transaction.set_current source.source_value value;
            Var.queue_var source;
            `Updated
          | Timer.Daemon_stop -> `Stopped)

    let add_relative_deadline = Timer.add_relative_deadline

    let timer_read_next_due timer generation fallback =
      with_graph_lane_sync (fun () ->
          Timer.read_next_due (timer_effective_state timer) ~generation
            ~fallback)

    let timer_set_next_due timer generation next_due_ms =
      with_graph_lane_sync (fun () ->
          match
            Timer.set_next_due ~effective_state:(timer_effective_state timer)
              ~current_state:(timer_current_state timer) ~generation
              ~next_due_ms
          with
          | Some state ->
              set_timer_current_state timer state;
              `Continue
          | None -> `Stop)

    let timer_advance_next_due timer generation ~expected next_due_ms =
      with_graph_lane_sync (fun () ->
          match
            Timer.advance_next_due
              ~effective_state:(timer_effective_state timer)
              ~current_state:(timer_current_state timer) ~generation
              ~expected ~next_due_ms
          with
          | Timer.Advance_next_due_update state ->
              set_timer_current_state timer state;
              `Advanced
          | Timer.Advance_next_due_stale -> `Stale
          | Timer.Advance_next_due_stop -> `Stop)

    let rec run_timer_update_batch timer generation remaining update ~missed =
      if remaining <= 0 then Effect.pure `Continue
      else
        timer_after_update_state timer generation
        |> Effect.bind (function
             | `Stop -> Effect.pure `Stop
             | `Continue ->
                 Effect.sync (fun () ->
                     update.timer_update timer generation ~missed)
                 |> Effect.bind (fun update_eff ->
                        Private_test_hooks.run
                          After_timer_update_constructed_before_run
                        |> Effect.bind (fun () -> update_eff))
                 |> Effect.bind (fun () ->
                        run_timer_update_batch timer generation (remaining - 1)
                          update ~missed))

    let rec run_timer_updates timer generation remaining update ~missed =
      match Timer.update_batch ~remaining with
      | None -> Effect.unit
      | Some batch ->
        run_timer_update_batch timer generation batch.update_batch_count update
          ~missed
        |> Effect.bind (function
             | `Stop -> Effect.unit
             | `Continue ->
                 if not batch.update_batch_yield then Effect.unit
                 else
                   Effect.yield
                   |> Effect.bind (fun () ->
                          run_timer_updates timer generation
                            batch.update_batch_remaining update ~missed))

    let rec timer_loop timer generation interval_ms next_due_ms update =
      timer_read_next_due timer generation next_due_ms
      |> Effect.bind (function
           | None -> Effect.unit
           | Some next_due_ms ->
               Effect.now
               |> Effect.bind (fun now_ms ->
                      let delay_ms =
                        Timer.sleep_delay_ms ~now_ms ~next_due_ms
                      in
                      Effect.sleep (Duration.ms delay_ms))
               |> Effect.bind (fun () ->
                      timer_read_next_due timer generation next_due_ms
                      |> Effect.bind (function
                           | None -> Effect.unit
                           | Some due_ms ->
                               Effect.now
                               |> Effect.bind (fun now_ms ->
                                      let wake =
                                        Timer.daemon_wake_plan
                                          ~catch_up_policy:
                                            update.timer_catch_up_policy
                                          ~interval_ms ~next_due_ms:due_ms
                                          ~now_ms
                                      in
                                      let next_due_ms =
                                        wake.wake_next_due_ms
                                      in
                                      let update_count =
                                        wake.wake_update_count
                                      in
                                      let update_missed =
                                        wake.wake_update_missed
                                      in
                                      let saturated_due =
                                        wake.wake_saturated_due
                                      in
                                      Private_test_hooks.run
                                        After_timer_due_read_before_commit
                                      |> Effect.bind (fun () ->
                                             timer_advance_next_due timer
                                               generation ~expected:due_ms
                                               next_due_ms
                                             |> Effect.bind (function
                                                  | `Stop -> Effect.unit
                                                  | `Stale ->
                                                      timer_loop timer generation
                                                        interval_ms next_due_ms
                                                        update
                                                  | `Advanced ->
                                                      run_timer_updates timer
                                                        generation update_count
                                                        update ~missed:update_missed
                                                      |> Effect.bind (fun () ->
                                                             (if saturated_due then
                                                                with_graph_lane_sync
                                                                  (fun () ->
                                                                    Option.iter
                                                                      (set_timer_current_state
                                                                         timer)
                                                                      (Timer.finish_current_daemon
                                                                         ~advance_generation:
                                                                           (checked_succ
                                                                              "timer generation")
                                                                         ~effective_state:
                                                                           (timer_effective_state
                                                                              timer)
                                                                         ~current_state:
                                                                           (timer_current_state
                                                                              timer)
                                                                         ~generation))
                                                              else Effect.unit)
                                                             |> Effect.bind
                                                                  (fun () ->
                                                                    timer_after_update_state
                                                                      timer
                                                                      generation
                                                                    |> Effect.bind
                                                                         (function
                                                                         | `Continue ->
                                                                             timer_loop
                                                                               timer
                                                                               generation
                                                                               interval_ms next_due_ms
                                                                               update
                                                                         | `Stop ->
                                                                             Effect.unit)))))))))

    let attach_timer ?(update_on_start = false) ?(refresh_when_inactive = true)
        ?refresh_operation ~runtime_contract signal interval update =
      let timer =
        {
          timer_snapshot =
            Transaction.create_staged Timer.initial_snapshot;
          timer_staged_refresh_token = -1;
          timer_runtime_contract = runtime_contract;
          timer_refresh_when_inactive = refresh_when_inactive;
          timer_refresh_operation = refresh_operation;
          timer_start =
            (fun timer ->
              let generation = timer_generation timer in
              let interval_ms = Duration.to_ms interval in
              let start_loop () =
                Effect.now
                |> Effect.bind (fun now_ms ->
                       let next_due_ms =
                         Timer.initial_next_due_ms ~now_ms ~interval_ms
                       in
                       timer_set_next_due timer generation next_due_ms
                       |> Effect.bind (function
                            | `Stop -> Effect.unit
                            | `Continue ->
                                Effect.daemon
                                  (cancellable_timer_loop timer generation
                                     (timer_loop timer generation interval_ms
                                        next_due_ms update
                                     |> Effect.on_exit
                                          (timer_cleanup_after_exit timer
                                             generation)))))
              in
              let start =
                if update_on_start then
                  update.timer_update timer generation ~missed:1
                  |> Effect.bind (fun () ->
                         timer_after_update_state timer generation
                         |> Effect.bind (function
                              | `Continue -> start_loop ()
                              | `Stop -> Effect.unit))
                else start_loop ()
              in
              timer_begin_start timer generation
              |> Effect.bind (function
                   | `Stop -> Effect.unit
                   | `Continue ->
                       start
                       |> Effect.on_exit
                            (timer_cleanup_failed_start timer generation));
            );
        }
      in
      signal.timer <- Some timer;
      signal

    let timer_refresh_operation source spec =
      Refresh_operation (source, spec)

    let make_timer_signal ?equal initial interval ~runtime_contract
        source_policy update =
      let source = Var.create ?equal initial in
      let signal = Var.watch source in
      let refresh_operation =
        Option.map (timer_refresh_operation source)
          source_policy.Timer.source_refresh_on_demand
      in
      attach_timer
        ~update_on_start:source_policy.Timer.source_update_on_start
        ~refresh_when_inactive:
          source_policy.Timer.source_refresh_when_inactive
        ?refresh_operation ~runtime_contract signal interval
        {
          timer_catch_up_policy =
            source_policy.Timer.source_catch_up_policy;
          timer_update =
            (fun timer generation ~missed ->
              update.source_timer_update timer generation ~missed source);
        }

    let construct_timer_signal f =
      with_graph_lane_sync (fun () ->
          try
            ignore (signal_scope ());
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
                                 (Timer.current_time_source_policy ())
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
            (Timer.deadline_source_policy ~deadline_ms)
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

    let deadline ~every deadline_ms =
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
                          (Timer.interval_source_policy ~interval_ms)
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
                          (Timer.step_source_policy ())
                          {
                            source_timer_update =
                              (fun timer generation ~missed source ->
                                timer_after_update_state timer generation
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
                          (Timer.step_replay_source_policy ())
                          {
                            source_timer_update =
                              (fun timer generation ~missed:_ source ->
                                timer_after_update_state timer generation
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

    let bridge_observer_delivery observer_delivery =
      {
        Stream_bridge.observer_update = observer_delivery.Observer.update;
        observer_current_token = observer_delivery.Observer.current_token;
        observer_acknowledge_sent = observer_delivery.Observer.acknowledge_sent;
        observer_acknowledge_drop = observer_delivery.Observer.acknowledge_drop;
      }

    let bridge_hooks () =
      Stream_bridge.hooks ~metrics:graph.stream_bridge_metrics
        ~after_try_send_before_ack:(fun () ->
          Private_test_hooks.run After_stream_try_send_before_ack)
        ~after_drop_before_ack:(fun () ->
          Private_test_hooks.run After_stream_drop_before_ack)
        ~on_closed_with_error:(fun err ->
          Effect.sync (fun () -> raise (Graph_error err)))
        ()

    let observe ?(capacity = default_capacity) ?on_drop ?equal signal =
      Stream_bridge.observe ~capacity ?on_drop ?equal
        ~hooks:(bridge_hooks ())
        ~map_observe_error:(fun err -> (err :> stream_error))
        ~observe_delivery:
          (fun ?equal ~on_finish signal callback ->
            Observer.observe_delivery ?equal ~on_finish signal (fun delivery ->
                callback (bridge_observer_delivery delivery)))
        signal
  end
end
