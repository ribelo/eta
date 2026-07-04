module Effect = Eta.Effect
module Duration = Eta.Duration
module Queue = Eta.Queue
module Runtime_contract = Eta.Runtime_contract
module Sync_lock = Eta.Sync_lock
module Bind = Eta_signal_bind
module Debug = Eta_signal_debug
module Error = Eta_signal_error
module Id = Eta_signal_id
module Kernel = Eta_signal_kernel
module Observer_core = Eta_signal_observer
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

  type weak_packed_signal = Obj.t Weak.t

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
    snapshot : 'a signal_snapshot Transaction.staged;
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

  and 'a signal_snapshot = {
    signal_value : 'a option;
    signal_initialized : bool;
    signal_version : int;
    signal_dependency_versions : (signal_id * int) list;
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

  and observer_after_ack_action = After_ack_record_stream_bridge_drop

  and 'a observer_delivery_state =
    ('a, observer_after_ack_action) Observer_core.Delivery.t

  and 'a observer_snapshot = {
    observer_value : 'a Observer_core.Value.t;
    observer_delivery : 'a observer_delivery_state;
  }

  and 'a observer_live_state = {
    observer_snapshot : 'a observer_snapshot Transaction.staged;
    mutable obs_on_finish : (Observer_lifecycle.finish_reason -> unit) list;
  }

  and 'a observer_state =
    ('a observer_live_state, 'a Observer_core.Value.t) Observer_lifecycle.t

  and 'a observer = {
    obs_id : observer_id;
    obs_signal : 'a signal;
    obs_equal : 'a -> 'a -> bool;
    obs_callback : 'a update -> (unit, observer_error) Effect.t;
    mutable obs_state : 'a observer_state;
  }

  and packed_observer = O : 'a observer -> packed_observer

  and timer_state = Timer.state =
    | Timer_inactive of int
    | Timer_starting of int
    | Timer_running_uncancellable of int * int option
    | Timer_running of int * int option * (unit -> unit)
    | Timer_finished of int

  and _ timer_refresh_spec =
    | Refresh_current_time : int timer_refresh_spec
    | Refresh_deadline : int -> bool timer_refresh_spec
    | Refresh_interval : int -> int timer_refresh_spec

  and timer_refresh_operation =
    | Refresh_current_time_source of int var
    | Refresh_deadline_source of bool var * int
    | Refresh_interval_source of int var * int

  and timer_transition =
    | Set_source : 'a var * 'a -> timer_transition
    | Advance_due of int
    | Finish
    | Cancel_after_commit of (unit -> unit)

  and timer_snapshot = {
    timer_state : timer_state;
    timer_on_demand_refresh_token : int;
  }

  and timer_node = {
    timer_snapshot : timer_snapshot Transaction.staged;
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

  and dead_timer = {
    dead_timer_active : bool;
    dead_timer_running_generation : int option;
    dead_timer_cancel : bool;
    dead_timer_finished : bool;
    dead_timer_generation : int;
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
    dead_timer : dead_timer option;
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
        { snapshot with observer_delivery }

    let observer_delivery observer =
      let live = active_live_state observer in
      match (observer_current_snapshot live).observer_delivery with
      | Observer_never_delivered -> Test_delivery_never_delivered
      | Observer_delivered value -> Test_delivery_delivered value
      | Observer_delivery_pending (token, update, _) ->
          Test_delivery_pending (token, update)
      | Observer_delivery_running (token, update, _) ->
          Test_delivery_running (token, update)

    let signal_version signal =
      (Transaction.current signal.snapshot).signal_version

    let set_signal_version signal value =
      let snapshot = Transaction.current signal.snapshot in
      Transaction.set_current signal.snapshot
        { snapshot with signal_version = value }
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
            {
              snapshot with
              timer_state =
                Timer.state_with_generation snapshot.timer_state generation;
            }

    let set_timer_next_due signal next_due_ms =
      match signal.timer with
      | None ->
          invalid_arg "Eta_signal.Private_test_hooks: expected timer signal"
      | Some timer -> (
          let snapshot = Transaction.current timer.timer_snapshot in
          match snapshot.timer_state with
          | Timer_running_uncancellable (generation, _) ->
              Transaction.set_current timer.timer_snapshot
                {
                  snapshot with
                  timer_state =
                    Timer_running_uncancellable (generation, Some next_due_ms);
                }
          | Timer_running (generation, _, cancel) ->
              Transaction.set_current timer.timer_snapshot
                {
                  snapshot with
                  timer_state =
                    Timer_running (generation, Some next_due_ms, cancel);
                }
          | Timer_inactive _ | Timer_starting _ | Timer_finished _ ->
              invalid_arg
                "Eta_signal.Private_test_hooks: expected active timer state")

    let timer_state signal =
      match signal.timer with
      | None ->
          invalid_arg "Eta_signal.Private_test_hooks: expected timer signal"
      | Some timer ->
          Timer.state_label
            ((Transaction.current timer.timer_snapshot).timer_state)

    let set_observer_on_finish observer hooks =
      let live =
        match Observer_lifecycle.live observer.obs_state with
        | Some live -> live
        | None ->
            invalid_arg
              "Eta_signal.Private_test_hooks: expected live observer state"
      in
      live.obs_on_finish <- hooks

    let run_observer_callback observer update = observer.obs_callback update
  end

  type disposal_hook = unit -> unit

  type event = E : int * 'a observer * 'a update -> event

  type pure_stabilize_result =
    | Pure_ok of disposal_hook list * event list
    | Pure_graph_error of disposal_hook list * graph_error
    | Pure_defect of disposal_hook list * exn * Printexc.raw_backtrace

  type lane_waiter_state =
    | Lane_waiting
    | Lane_granted
    | Lane_cancelled

  type lane_claim_result =
    | Lane_grant_accepted
    | Lane_grant_cancelled

  type lane_waiter = {
    lane_contract : Runtime_contract.t;
    lane_resolver : unit Runtime_contract.resolver;
    mutable lane_state : lane_waiter_state;
    mutable lane_notified : bool;
  }

  type lane = {
    lane_lock : Sync_lock.t;
    lane_waiters : lane_waiter Stdlib.Queue.t;
    mutable lane_busy : bool;
    mutable lane_waiting : int;
    mutable lane_cancelled : int;
    mutable lane_cancelled_debt : int;
    mutable lane_owner_fiber_id : int option;
  }

  type timer_refresh_context = {
    timer_refresh_token : int;
    timer_refresh_runtime_contract : Runtime_contract.t;
    timer_refresh_now_ms : unit -> int;
    mutable timer_refresh_sample_ms : int option;
    mutable timer_refresh_dirty_nodes : (packed_signal * bool) list;
  }

  type graph = {
    lane : lane;
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
    mutable stream_bridge_drop_count : int;
    mutable necessary_node_ids : (signal_id, unit) Hashtbl.t;
    mutable next_timer_refresh_token : int;
    mutable active_timer_refresh : timer_refresh_context option;
  }

  let graph =
    {
      lane =
        {
          lane_lock = Sync_lock.create ();
          lane_waiters = Stdlib.Queue.create ();
          lane_busy = false;
          lane_waiting = 0;
          lane_cancelled = 0;
          lane_cancelled_debt = 0;
          lane_owner_fiber_id = None;
        };
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
      stream_bridge_drop_count = 0;
      necessary_node_ids = Hashtbl.create 16;
      next_timer_refresh_token = 0;
      active_timer_refresh = None;
    }

  let weak_packed_signal (P signal) =
    let cell = Weak.create 1 in
    (* Store the signal record itself, not the short-lived existential wrapper. *)
    Weak.set cell 0 (Some (Obj.repr signal));
    cell

  let weak_packed_signal_value cell =
    match Weak.get cell 0 with
    | None -> None
    | Some signal -> Some (P (Obj.obj signal))

  let collect_live_weak_signals keep cells =
    let rec loop kept_cells kept_signals = function
      | [] -> (List.rev kept_cells, List.rev kept_signals)
      | cell :: rest -> (
          match weak_packed_signal_value cell with
          | None -> loop kept_cells kept_signals rest
          | Some packed ->
              if keep packed then
                loop (cell :: kept_cells) (packed :: kept_signals) rest
              else loop kept_cells kept_signals rest)
    in
    loop [] [] cells

  let all_nodes_unlocked () =
    let cells, nodes = collect_live_weak_signals (fun _ -> true) graph.all_nodes in
    graph.all_nodes <- cells;
    nodes

  let prune_all_nodes_unlocked () =
    ignore (all_nodes_unlocked () : packed_signal list)

  let scope_owner_signal signal =
    match signal.scope with
    | Some scope when Scope.valid scope ->
        let (P owner as packed_owner) = Scope.owner scope in
        if owner.valid then Some packed_owner else None
    | None | Some _ -> None

  let children_with_scope_owner signal children =
    match scope_owner_signal signal with
    | None -> children
    | Some owner -> owner :: children

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

  let with_lane_lock lane f = Sync_lock.use lane.lane_lock f

  let lane_invariant_failed message =
    invalid_arg ("Eta_signal invariant failed: " ^ message)

  let decrement_lane_cancelled_debt lane =
    if lane.lane_cancelled_debt > 0 then
      lane.lane_cancelled_debt <- lane.lane_cancelled_debt - 1

  let rec take_waiting_waiter_locked lane =
    if Stdlib.Queue.is_empty lane.lane_waiters then None
    else
      let waiter = Stdlib.Queue.take lane.lane_waiters in
      match waiter.lane_state with
      | Lane_waiting -> Some waiter
      | Lane_granted -> take_waiting_waiter_locked lane
      | Lane_cancelled ->
          decrement_lane_cancelled_debt lane;
          take_waiting_waiter_locked lane

  let should_compact_cancelled retained_cancelled queue_length =
    if retained_cancelled <= 0 || queue_length <= 0 then false
    else
      let half_rounded_up = (queue_length / 2) + (queue_length mod 2) in
      retained_cancelled >= max 1 half_rounded_up

  let compact_cancelled_lane_waiters_locked lane =
    if
      should_compact_cancelled lane.lane_cancelled_debt
        (Stdlib.Queue.length lane.lane_waiters)
    then (
      let live = Stdlib.Queue.create () in
      Stdlib.Queue.iter
        (fun waiter ->
          match waiter.lane_state with
          | Lane_waiting -> Stdlib.Queue.push waiter live
          | Lane_granted | Lane_cancelled -> ())
        lane.lane_waiters;
      Stdlib.Queue.clear lane.lane_waiters;
      Stdlib.Queue.iter
        (fun waiter -> Stdlib.Queue.push waiter lane.lane_waiters)
        live;
      lane.lane_cancelled_debt <- 0;
      Private_test_hooks.note_lane_waiter_compaction ())

  let add_lane_grant pending waiter = Stdlib.Queue.push waiter pending

  let grant_lane_waiter_locked pending waiter =
    waiter.lane_state <- Lane_granted;
    add_lane_grant pending waiter;
    waiter

  let resolve_lane_waiter waiter =
    waiter.lane_contract.Runtime_contract.protect (fun () ->
        waiter.lane_contract.Runtime_contract.resolve_promise
          waiter.lane_resolver ();
        waiter.lane_notified <- true)

  let rec resolve_lane_waiter_best_effort remaining waiter =
    (* Lane grants are already committed. Runtime_contract requires resolver
       notification to fail only for non-transient programmer/runtime boundary
       errors, so a grant-resolution failure must not poison the operation
       that released the lane. *)
    try
      resolve_lane_waiter waiter;
      true
    with _exn ->
      waiter.lane_notified
      || (remaining > 0
         && resolve_lane_waiter_best_effort (remaining - 1) waiter)

  let resolve_pending_lane_grants pending =
    let rec loop () =
      if not (Stdlib.Queue.is_empty pending) then (
        let waiter = Stdlib.Queue.take pending in
        ignore (resolve_lane_waiter_best_effort 1 waiter : bool);
        loop ())
    in
    loop ()

  let with_committed_lane_grant lock f =
    let pending_grants = Stdlib.Queue.create () in
    Fun.protect
      ~finally:(fun () -> resolve_pending_lane_grants pending_grants)
      (fun () ->
        let result = lock (fun () -> f pending_grants) in
        resolve_pending_lane_grants pending_grants;
        result)

  let release_lane_locked pending_grants lane =
    match take_waiting_waiter_locked lane with
    | Some waiter ->
        lane.lane_waiting <- lane.lane_waiting - 1;
        ignore (grant_lane_waiter_locked pending_grants waiter)
    | None -> lane.lane_busy <- false

  let cancel_lane_waiter_locked pending_grants lane waiter =
    match waiter.lane_state with
    | Lane_waiting ->
        waiter.lane_state <- Lane_cancelled;
        lane.lane_waiting <- lane.lane_waiting - 1;
        lane.lane_cancelled <- saturating_succ lane.lane_cancelled;
        lane.lane_cancelled_debt <- saturating_succ lane.lane_cancelled_debt;
        compact_cancelled_lane_waiters_locked lane
    | Lane_granted ->
        waiter.lane_state <- Lane_cancelled;
        lane.lane_cancelled <- saturating_succ lane.lane_cancelled;
        release_lane_locked pending_grants lane
    | Lane_cancelled -> ()

  let claim_lane_waiter_locked waiter =
    match waiter.lane_state with
    | Lane_granted -> Lane_grant_accepted
    | Lane_waiting ->
        lane_invariant_failed "lane waiter was not granted"
    | Lane_cancelled -> Lane_grant_cancelled

  let with_lane_lock_during_cancel contract lane f =
    contract.Runtime_contract.protect (fun () -> with_lane_lock lane f)

  let enqueue_lane_waiter contract lane =
    let promise, resolver = contract.Runtime_contract.create_promise () in
    let waiter =
      {
        lane_contract = contract;
        lane_resolver = resolver;
        lane_state = Lane_waiting;
        lane_notified = false;
      }
    in
    Stdlib.Queue.push waiter lane.lane_waiters;
    Private_test_hooks.note_lane_waiter_enqueued ();
    lane.lane_waiting <- saturating_succ lane.lane_waiting;
    (promise, waiter)

  let enter_lane_sync contract lane =
    match
      with_lane_lock lane @@ fun () ->
      if lane.lane_busy then
        let promise, waiter = enqueue_lane_waiter contract lane in
        `Wait (promise, waiter)
      else (
        lane.lane_busy <- true;
        `Ready)
    with
    | `Ready -> ()
    | `Wait (promise, waiter) -> (
        let claimed = ref false in
        try
          contract.Runtime_contract.await_promise promise;
          (match
             with_lane_lock_during_cancel contract lane (fun () ->
                 match claim_lane_waiter_locked waiter with
                 | Lane_grant_accepted ->
                     claimed := true;
                     Lane_grant_accepted
                 | Lane_grant_cancelled -> Lane_grant_cancelled)
           with
           | Lane_grant_accepted -> ()
           | Lane_grant_cancelled -> contract.Runtime_contract.await_cancel ())
        with exn
          when Option.is_some (contract.Runtime_contract.cancellation_reason exn) ->
          (if !claimed then
             with_committed_lane_grant
               (fun f -> with_lane_lock_during_cancel contract lane f)
               (fun pending_grants ->
                 release_lane_locked pending_grants lane)
           else
             with_committed_lane_grant
               (fun f -> with_lane_lock_during_cancel contract lane f)
               (fun pending_grants ->
                 cancel_lane_waiter_locked pending_grants lane waiter));
          raise exn)

  let leave_lane_sync lane =
    with_committed_lane_grant (with_lane_lock lane) (fun pending_grants ->
        release_lane_locked pending_grants lane)

  let graph_lane_depth_local : int Runtime_contract.local =
    Runtime_contract.create_local ()

  let release_graph_lane_sync owns_lane =
    if !owns_lane then (
      owns_lane := false;
      graph.lane.lane_owner_fiber_id <- None;
      leave_lane_sync graph.lane)

  let with_graph_lane_sync f =
    Effect.Expert.make ~leaf_name:"Eta_signal.with_graph_lane_sync" (fun context ->
        let contract = Effect.Expert.contract context in
        let lane_depth =
          Option.value
            (contract.Runtime_contract.local_get graph_lane_depth_local)
            ~default:0
        in
        let current_fiber_id = contract.Runtime_contract.current_fiber_id () in
        let owns_graph_lane =
          match graph.lane.lane_owner_fiber_id with
          | Some owner_fiber_id -> owner_fiber_id = current_fiber_id
          | None -> false
        in
        if lane_depth > 0 || owns_graph_lane then
          try
            ensure_graph_context ();
            Effect.Expert.eval context (Effect.sync f)
          with exn -> Effect.Expert.exit_of_exn context exn
        else
          let owns_lane = ref false in
          let release_after_interrupt () =
            contract.Runtime_contract.protect (fun () ->
                release_graph_lane_sync owns_lane)
          in
          try
            ensure_graph_context ();
            enter_lane_sync contract graph.lane;
            owns_lane := true;
            graph.lane.lane_owner_fiber_id <- Some current_fiber_id;
            let release_graph_lane =
              Effect.sync (fun () -> release_graph_lane_sync owns_lane)
            in
            contract.Runtime_contract.local_with_binding graph_lane_depth_local 1
              (fun () ->
                Effect.Expert.eval context
                  (Private_test_hooks.run After_graph_lane_acquired
                  |> Effect.bind (fun () -> Effect.sync f)
                  |> Effect.on_exit (fun _exit -> release_graph_lane)))
          with
          | exn
            when Option.is_some
                   (contract.Runtime_contract.cancellation_reason exn) ->
              release_after_interrupt ();
              raise exn
          | exn ->
              release_after_interrupt ();
              Effect.Expert.exit_of_exn context exn)

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
         context.timer_refresh_dirty_nodes <-
           Kernel_dirty.mark_recording_previous
             context.timer_refresh_dirty_nodes packed

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
        let signal_version =
          if snapshot.signal_version = current.signal_version then
            checked_succ "signal version" snapshot.signal_version
          else snapshot.signal_version
        in
        {
          snapshot with
          signal_value = Some value;
          signal_initialized = true;
          signal_version;
        })

  let effective_signal_version signal =
    (signal_effective_snapshot signal).signal_version

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
      ~current:(signal_current_snapshot signal).signal_dependency_versions
      dependencies

  let stage_dependency_versions signal dependencies =
    update_signal_staging signal (fun snapshot ->
        {
          snapshot with
          signal_dependency_versions = dependency_versions dependencies;
        })

  let effective_signal_value signal =
    match (signal_effective_snapshot signal).signal_value with
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
    set_observer_current live { snapshot with observer_delivery }

  let stage_observer_value_state observer value =
    let live = live_state_or_invalid_arg observer "stage" in
    update_observer_staging live (fun snapshot ->
        { snapshot with observer_value = value })

  let stage_observer_delivery_state observer state =
    let live = live_state_or_invalid_arg observer "stage delivery for" in
    update_observer_staging live (fun snapshot ->
        { snapshot with observer_delivery = state })

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
    (observer_current_snapshot live).observer_value

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
    set_timer_current_snapshot timer { snapshot with timer_state }

  let update_timer_staging timer f =
    let transaction = active_transaction () in
    let snapshot = Transaction.read transaction timer.timer_snapshot in
    Transaction.stage transaction timer.timer_snapshot (f snapshot)

  let timer_current_state timer =
    (timer_current_snapshot timer).timer_state

  let timer_generation timer =
    timer_state_generation (timer_current_state timer)

  let timer_state_label = Timer.state_label

  let timer_has_staged_refresh timer =
    match graph.active_timer_refresh with
    | Some { timer_refresh_token; _ } ->
        timer.timer_staged_refresh_token = timer_refresh_token
    | None -> false

  let timer_effective_state timer =
    if timer_has_staged_refresh timer then
      (timer_effective_snapshot timer).timer_state
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
        (timer_current_snapshot timer).timer_on_demand_refresh_token
      ~staged_token:timer.timer_staged_refresh_token ~token
      ~refresh_when_inactive:timer.timer_refresh_when_inactive
      ~active:(timer_active timer) ~finished:(timer_finished timer)

  let timer_running_generation timer =
    Timer.state_running_generation (timer_effective_state timer)

  let timer_has_cancel timer =
    Timer.state_has_cancel (timer_effective_state timer)

  let add_ms_capped = Timer.add_ms_capped
  let add_int_capped = Timer.add_int_capped
  let missed_cadences = Timer.missed_cadences
  let advance_due = Timer.advance_due

  let timer_set_next_due_state = Timer.state_set_next_due

  let remember_timer_refresh_timer timer =
    match graph.active_timer_refresh with
    | None -> ()
    | Some { timer_refresh_token; _ } ->
        if timer.timer_staged_refresh_token <> timer_refresh_token then (
          timer.timer_staged_refresh_token <- timer_refresh_token;
          update_timer_staging timer (fun snapshot ->
              {
                snapshot with
                timer_on_demand_refresh_token = timer_refresh_token;
              });
          graph.timer_refresh_staged_timers <-
            timer :: graph.timer_refresh_staged_timers)

  let stage_timer_state_unlocked timer state =
    remember_timer_refresh_timer timer;
    update_timer_staging timer (fun snapshot ->
        { snapshot with timer_state = state })

  let timer_mark_unneeded_unlocked ?(cancel_running = true) timer =
    match
      Timer.stop
        ~advance_generation:(checked_succ "timer generation")
        ~cancel_running (timer_current_state timer)
    with
    | None -> []
    | Some plan ->
        set_timer_current_state timer plan.stop_state;
        plan.stop_cancel_hooks

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
          Transaction.create_staged
            {
              signal_value = None;
              signal_initialized = false;
              signal_version = 0;
              signal_dependency_versions = [];
            };
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
      {
        signal_value = Some value;
        signal_initialized = true;
        signal_version = 0;
        signal_dependency_versions = [];
      };
    signal

  let prune_invalid_nodes_unlocked () =
    let cells, _ =
      collect_live_weak_signals (fun (P signal) -> signal.valid) graph.all_nodes
    in
    graph.all_nodes <- cells

  let max_dead_signal_tombstones = 1024

  let rec take_dead_signal_tombstones remaining = function
    | [] -> []
    | _ when remaining <= 0 -> []
    | tombstone :: rest ->
        tombstone :: take_dead_signal_tombstones (remaining - 1) rest

  let timer_tombstone timer =
    {
      dead_timer_active = timer_active timer;
      dead_timer_running_generation = timer_running_generation timer;
      dead_timer_cancel = timer_has_cancel timer;
      dead_timer_finished = timer_finished timer;
      dead_timer_generation = timer_generation timer;
    }

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
      dead_initialized = snapshot.signal_initialized;
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
      signal_tombstone packed
      :: List.filter
           (fun tombstone -> tombstone.dead_id <> signal.id)
           graph.dead_nodes
      |> take_dead_signal_tombstones max_dead_signal_tombstones

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
    match (signal_current_snapshot signal).signal_value with
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
    (* Scope invalidation stops active timers during commit. Check generation
       overflow before commit mutates staged graph state; the actual stop
       happens later in [invalidate_scope]. *)
    if Timer.needs_stop ~effective_state:(timer_effective_state timer) then
      ignore (checked_succ "timer generation" (timer_generation timer) : int)

  let preflight_timer_start timer =
    ignore
      (Timer.start
         ~advance_generation:(checked_succ "timer generation")
         ~effective_state:(timer_effective_state timer)
         ~current_state:(timer_current_state timer)
        : Timer.start_plan option)

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
      if staged.signal_version <> current.signal_version then
        ignore (checked_succ "signal version" current.signal_version : int)

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
              P bind.source
              ::
              (match bind_effective_inner bind with
               | None -> []
               | Some inner -> [ P inner ])
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

  let rec stage_timer_transition timer = function
    | Set_source (source, value) ->
        stage_timer_source_value source value
    | Advance_due next_due_ms ->
        stage_timer_state_unlocked timer
          (timer_set_next_due_state (timer_effective_state timer)
             (Some next_due_ms))
    | Finish ->
        let state = timer_effective_state timer in
        let plan = timer_finish_plan state in
        stage_timer_state_unlocked timer plan.finish_state;
        List.iter
          (fun cancel ->
            stage_timer_transition timer (Cancel_after_commit cancel))
          plan.finish_cancel_hooks
    | Cancel_after_commit cancel ->
        remember_timer_refresh_disposal_hooks [ cancel ]

  let timer_refresh_transitions source refresh =
    Timer.refresh_transitions refresh
    |> List.map (function
         | Timer.Refresh_set value -> Set_source (source, value)
         | Timer.Refresh_advance_due next_due_ms -> Advance_due next_due_ms
         | Timer.Refresh_finish -> Finish)

  let timer_refresh_plan timer now_ms = function
    | Refresh_current_time_source source ->
        Timer.current_time_refresh_plan ~now_ms
        |> timer_refresh_transitions source
    | Refresh_deadline_source (source, deadline_ms) ->
        Timer.deadline_refresh_plan ~now_ms ~deadline_ms
        |> timer_refresh_transitions source
    | Refresh_interval_source (source, interval_ms) ->
        Timer.interval_refresh_plan ~state:(timer_effective_state timer)
          ~interval_ms ~current_value:(effective_var_value source) ~now_ms
        |> timer_refresh_transitions source

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
        Kernel_dirty.restore context.timer_refresh_dirty_nodes;
        context.timer_refresh_dirty_nodes <- []

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
          {
            snapshot with
            observer_value =
              Observer_core.Value.mark_failed_without_current
                snapshot.observer_value;
          }
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

  let timer_refresh_sample_now_ms context =
    match context.timer_refresh_sample_ms with
    | Some now_ms -> now_ms
    | None ->
        let now_ms = context.timer_refresh_now_ms () in
        context.timer_refresh_sample_ms <- Some now_ms;
        now_ms

  let refresh_timer_source_for_compute signal =
    match (graph.active_timer_refresh, signal.timer) with
    | Some
        ( { timer_refresh_token; timer_refresh_runtime_contract; _ } as
        timer_refresh ),
      Some timer ->
        ensure_timer_runtime timer timer_refresh_runtime_contract;
        if timer_can_refresh_on_demand timer_refresh_token timer then (
          remember_timer_refresh_timer timer;
          let now_ms = timer_refresh_sample_now_ms timer_refresh in
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
      (signal_effective_snapshot signal).signal_initialized
    in
    let recompute value =
      graph.recompute_count <- saturating_succ graph.recompute_count;
      let snapshot = signal_effective_snapshot signal in
      let changed =
        Kernel.Value_cutoff.changed ~equal:signal.equal
          ~initialized:snapshot.signal_initialized
          ~current:snapshot.signal_value ~next:value
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
      if
        Kernel.Static_eval.should_recompute ~dirty:signal.dirty
          ~initialized:(signal_initialized ())
          ~dependencies_changed:dependency_changed result
      then
        let output = Kernel.Static_eval.output result in
        if stage_dependencies then
          recompute_with_dependencies (Kernel.Static_eval.dependencies result)
            output
        else recompute output
      else use_cached ()
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
          let dependencies = [ P bind.source; P inner ] in
          graph.recompute_count <- saturating_succ graph.recompute_count;
          let snapshot = signal_effective_snapshot signal in
          let changed =
            Kernel.Value_cutoff.changed ~equal:signal.equal
              ~initialized:snapshot.signal_initialized
              ~current:snapshot.signal_value ~next:inner_value
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

  let timer_start_unlocked timer =
    match
      Timer.start
        ~advance_generation:(checked_succ "timer generation")
        ~effective_state:(timer_effective_state timer)
        ~current_state:(timer_current_state timer)
    with
    | None -> None
    | Some plan ->
        set_timer_current_state timer plan.start_state;
        Some { start_timer = timer; start_effect = timer.timer_start timer }

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
    let timer_actions =
      all_timers ()
      |> List.filter_map (fun (id, timer) ->
             let necessary = Hashtbl.mem needed id in
             if necessary then ensure_timer_runtime timer runtime_contract;
             (match
                Timer.demand_action ~necessary
                  ~effective_state:(timer_effective_state timer)
                  ~current_state:(timer_current_state timer)
              with
             | Timer.Demand_none -> None
             | Timer.Demand_start ->
                 preflight_timer_start timer;
                 Some (timer, Timer.Demand_start)
             | Timer.Demand_stop ->
                 preflight_timer_invalidation timer;
                 Some (timer, Timer.Demand_stop)))
    in
    let start_attempts = ref [] in
    let cancel_hooks = ref [] in
    List.iter
      (function
        | timer, Timer.Demand_start ->
            Option.iter
              (fun attempt -> start_attempts := attempt :: !start_attempts)
              (timer_start_unlocked timer)
        | timer, Timer.Demand_stop ->
            cancel_hooks :=
              List.rev_append (timer_mark_unneeded_unlocked timer) !cancel_hooks
        | _, Timer.Demand_none -> ())
      timer_actions;
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
        let dependencies = [ P bind.source ] in
        (match bind_effective_inner bind with
         | None -> dependencies
         | Some inner -> P inner :: dependencies)
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
        Observer_core.Event.plan ~equal:observer.obs_equal ~changed ~value
          snapshot.observer_delivery
      in
      Option.iter
        (stage_observer_delivery_state observer)
        event_plan.delivery;
      stage_observer_value_state observer event_plan.value;
      Option.map
        (fun update -> E (current_generation (), observer, update))
        event_plan.update

  let mark_event_pending (E (token, observer, update)) =
    match observer_active_live_state observer with
    | Some live ->
        set_observer_current_delivery live
          (Observer_core.Delivery.pending_state ~token update)
    | None -> ()

  let run_after_ack_action_unlocked = function
    | After_ack_record_stream_bridge_drop ->
        graph.stream_bridge_drop_count <-
          saturating_succ graph.stream_bridge_drop_count

  let run_after_ack_actions_unlocked actions =
    List.iter run_after_ack_action_unlocked actions

  let acknowledge_event_delivery observer token update =
    with_graph_lane_sync (fun () ->
        match observer_active_live_state observer with
        | None -> ()
        | Some live -> (
        let snapshot = observer_current_snapshot live in
        match
          Observer_core.Delivery.acknowledge ~token ~update ~after_ack:[]
            snapshot.observer_delivery
        with
        | Some (observer_delivery, after_ack) ->
            set_observer_current_delivery live observer_delivery;
            run_after_ack_actions_unlocked after_ack
        | None -> ()))

  let claim_event_delivery observer token =
    with_graph_lane_sync (fun () ->
        match observer_active_live_state observer with
        | None -> false
        | Some live -> (
        let snapshot = observer_current_snapshot live in
        match
          Observer_core.Delivery.claim ~token snapshot.observer_delivery
        with
        | Some observer_delivery ->
            set_observer_current_delivery live observer_delivery;
            true
        | None -> false))

  let release_event_delivery_claim observer token =
    with_graph_lane_sync (fun () ->
        match observer_active_live_state observer with
        | None -> ()
        | Some live -> (
        let snapshot = observer_current_snapshot live in
        match
          Observer_core.Delivery.release ~token snapshot.observer_delivery
        with
        | Some observer_delivery ->
            set_observer_current_delivery live observer_delivery
        | None -> ()))

  let finish_event_delivery_after_error observer token update ~delivered =
    with_graph_lane_sync (fun () ->
        match observer_active_live_state observer with
        | None -> ()
        | Some live -> (
            let snapshot = observer_current_snapshot live in
            match
              Observer_core.Delivery.finish_running ~token ~update
                ~delivered ~after_ack:[] snapshot.observer_delivery
            with
            | Some
                (Observer_core.Delivery.Finish_acknowledged
                  (observer_delivery, after_ack)) ->
                set_observer_current_delivery live observer_delivery;
                run_after_ack_actions_unlocked after_ack
            | Some
                (Observer_core.Delivery.Finish_released observer_delivery) ->
                set_observer_current_delivery live observer_delivery
            | None -> ()))

  let claimed_event_delivery_active observer token =
    match Observer_lifecycle.active_live observer.obs_state with
    | Some live ->
        (match
           Observer_core.Delivery.running_token
             (observer_current_snapshot live).observer_delivery
         with
         | Some running_token -> running_token = token
         | None -> false)
    | None -> false

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
        let committed_token =
          Stabilization.commit_to_committed graph.stabilization pure_token
        in
        ignore
          (Stabilization.collect_to_delivering graph.stabilization
             committed_token
            : Stabilization.delivering Stabilization.token);
        Pure_ok (hooks, events)
      with
      | Graph_error err ->
          let hooks = rollback_pure pure_token observers pending_at_start in
          Pure_graph_error (hooks, err)
      | exn ->
          let backtrace = Printexc.get_raw_backtrace () in
          let hooks = rollback_pure pure_token observers pending_at_start in
          Pure_defect (hooks, exn, backtrace)

  let finish_stabilize () =
    graph.active_timer_refresh <- None;
    Stabilization.finish graph.stabilization

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
            Ok (Some (observer.obs_callback update))
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

  let begin_stabilize_with_pending_hooks timer_refresh hooks_ref finish_needed =
    let result = begin_stabilize timer_refresh in
    let hooks =
      match result with
      | Pure_ok (hooks, _) | Pure_graph_error (hooks, _)
      | Pure_defect (hooks, _, _) ->
          hooks
    in
    hooks_ref := hooks;
    (match result with
     | Pure_ok _ -> finish_needed := true
     | Pure_graph_error _ | Pure_defect _ -> ());
    result

  let finish_stabilize_with_pending_cleanup hooks_ref refresh_timers
      finish_needed =
    run_pending_stabilize_cleanup hooks_ref refresh_timers
    |> Effect.on_exit (fun _exit ->
           if !finish_needed then with_graph_lane_sync finish_stabilize
           else Effect.unit)

  let stabilize =
    Effect.sync (fun () -> (ref [], ref false, ref false))
    |> Effect.bind
         (fun (hooks_ref, refresh_timers, finish_needed) ->
           current_runtime_contract ()
           |> Effect.bind (fun runtime_contract ->
                  with_graph_lane_sync (fun () ->
                      try
                        let timer_refresh =
                          Some
                            {
                              timer_refresh_token =
                                next_timer_refresh_token_unlocked ();
                              timer_refresh_runtime_contract =
                                runtime_contract;
                              timer_refresh_now_ms =
                                runtime_contract.Runtime_contract.now_ms;
                              timer_refresh_sample_ms = None;
                              timer_refresh_dirty_nodes = [];
                            }
                        in
                        begin_stabilize_with_pending_hooks timer_refresh
                          hooks_ref finish_needed
                      with Graph_error err -> Pure_graph_error ([], err))
                  |> Effect.bind (function
                       | Pure_graph_error (_, err) ->
                           graph_error_with_pending_disposal_hooks hooks_ref err
                       | Pure_defect (_, exn, backtrace) ->
                           defect_with_pending_disposal_hooks hooks_ref exn
                             backtrace
                       | Pure_ok (_, events) ->
                           refresh_timers := true;
                           run_pending_stabilize_cleanup hooks_ref refresh_timers
                           |> Effect.bind (fun () -> run_events events)
                           |> Effect.bind mark_callback_delivery_complete))
           |> Effect.on_exit (fun _exit ->
                  finish_stabilize_with_pending_cleanup hooks_ref refresh_timers
                    finish_needed))

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

    let observe_with_hooks_callback ?(equal = default_equal) ?(on_finish = [])
        signal callback =
      with_graph_lane_sync (fun () ->
          try
            if not signal.valid then Error `Invalid_scope
            else
              let live =
                {
                  observer_snapshot =
                    Transaction.create_staged
                      {
                        observer_value = Observer_core.Value.uninitialized;
                        observer_delivery = Observer_never_delivered;
                      };
                  obs_on_finish = on_finish;
                }
              in
              let rec observer =
                {
                  obs_id = next_observer_id ();
                  obs_signal = signal;
                  obs_equal = equal;
                  obs_callback = (fun update -> callback observer update);
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

    let observe_with_hooks ?equal ?on_finish signal callback =
      observe_with_hooks_callback ?equal ?on_finish signal
        (fun _observer update -> callback update)

    let observe ?equal signal callback = observe_with_hooks ?equal signal callback

    let read observer =
      with_graph_lane_sync (fun () ->
          Observer_lifecycle.read_value
            ~value_of_live:(fun live ->
              (observer_current_snapshot live).observer_value)
            observer.obs_state)
      |> Effect.flatten_result

    let unsafe_read_exn observer =
      ensure_graph_context ();
      Observer_lifecycle.unsafe_read_value_exn
        ~value_of_live:(fun live -> (observer_current_snapshot live).observer_value)
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
        if
          match observer.obs_state with
          | Observer_lifecycle.Invalid_scope _ -> true
          | Observer_lifecycle.Registering _ | Observer_lifecycle.Active _
          | Observer_lifecycle.Disposed _ -> false
        then
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
                  graph.stream_bridge_drop_count;
              lane_waiter_count =
                stats_counter "stats lane_waiter_count" graph.lane.lane_waiting;
              lane_cancelled_waiter_count =
                stats_counter "stats lane_cancelled_waiter_count"
                  graph.lane.lane_cancelled;
            }
        with Graph_error err -> Error err)
    |> Effect.flatten_result

  let acknowledge_stream_published_delivery observer token update
      after_ack_actions =
    with_graph_lane_sync (fun () ->
        match observer_active_live_state observer with
        | None -> ()
        | Some live -> (
        let snapshot = observer_current_snapshot live in
        match
          Observer_core.Delivery.acknowledge ~token ~update
            ~after_ack:after_ack_actions snapshot.observer_delivery
        with
        | Some (observer_delivery, after_ack) ->
            set_observer_current_delivery live observer_delivery;
            run_after_ack_actions_unlocked after_ack
        | None -> ()))

  let acknowledge_stream_sent_delivery observer token update =
    acknowledge_stream_published_delivery observer token update []

  let acknowledge_stream_drop_delivery observer token update =
    acknowledge_stream_published_delivery observer token update
      [ After_ack_record_stream_bridge_drop ]

  let stream_delivery_token observer =
    with_graph_lane_sync (fun () ->
        match observer_active_live_state observer with
        | None -> None
        | Some live ->
            Observer_core.Delivery.running_token
              (observer_current_snapshot live).observer_delivery)

  let signal_selected :
      type a. dot_options -> (signal_id, unit) Hashtbl.t -> a signal -> bool =
   fun options necessary signal ->
    match options.dot_scope with
    | `Necessary -> Hashtbl.mem necessary signal.id
    | `All_valid -> signal.valid
    | `All_including_invalid -> true

  let bool_field = Debug.bool_field

  let signal_state_fields : type a. a signal -> string list =
   fun signal ->
    let snapshot = signal_current_snapshot signal in
    let base =
      [
        bool_field "valid" signal.valid;
        bool_field "initialized" snapshot.signal_initialized;
        bool_field "dirty" signal.dirty;
        bool_field "computing" signal.computing;
        "dependencies=" ^ string_of_int (List.length signal.dependencies);
        "dependents=" ^ string_of_int (List.length signal.dependents);
      ]
    in
    match signal.kind with
    | Var source ->
        base
        @ [
            "var_id=" ^ var_id_label source.var_id;
            bool_field "queued" source.queued;
            bool_field "updating" source.updating;
          ]
    | Const _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _ | Map6 _ | Map7 _
    | Map8 _ | Map9 _ | All _ | Bind _ ->
        base

  let signal_scope_fields : type a. a signal -> string list =
   fun signal ->
    match signal.scope with
    | None ->
        [
          "scope=root";
          "scope_id=root";
          "scope_owner=root";
          "scope_parent=root";
        ]
    | Some scope ->
        let parent =
          match Scope.parent scope with
          | None -> "root"
          | Some parent -> scope_id_label (Scope.id parent)
        in
        [
          "scope="
          ^ scope_id_label (Scope.id scope)
          ^ ":"
          ^ (if Scope.valid scope then "valid" else "invalid");
          "scope_id=" ^ scope_id_label (Scope.id scope);
          "scope_owner=" ^ signal_id_label (scope_owner_id scope);
          "scope_parent=" ^ parent;
        ]

  let signal_timer_fields : type a. a signal -> string list =
   fun signal ->
    match signal.timer with
    | None -> []
    | Some timer ->
        let running =
          match timer_running_generation timer with
          | None -> "none"
          | Some generation -> string_of_int generation
        in
        [
          "timer_state=" ^ timer_state_label (timer_current_state timer);
          bool_field "timer_active" (timer_active timer);
          "timer_running=" ^ running;
          bool_field "timer_cancel" (timer_has_cancel timer);
          bool_field "timer_finished" (timer_finished timer);
          "timer_generation=" ^ string_of_int (timer_generation timer);
        ]

  let dead_signal_state_fields dead =
    [
      bool_field "valid" false;
      bool_field "initialized" dead.dead_initialized;
      bool_field "dirty" dead.dead_dirty;
      bool_field "computing" dead.dead_computing;
      "dependencies=" ^ string_of_int dead.dead_dependency_count;
      "dependents=" ^ string_of_int dead.dead_dependent_count;
    ]

  let dead_signal_scope_fields dead =
    match
      ( dead.dead_scope_id,
        dead.dead_scope_owner,
        dead.dead_scope_parent,
        dead.dead_scope_valid )
    with
    | None, None, None, None ->
        [
          "scope=root";
          "scope_id=root";
          "scope_owner=root";
          "scope_parent=root";
        ]
    | Some scope_id, Some owner, parent, Some scope_valid ->
        [
          "scope="
          ^ scope_id_label scope_id
          ^ ":"
          ^ (if scope_valid then "valid" else "invalid");
          "scope_id=" ^ scope_id_label scope_id;
          "scope_owner=" ^ signal_id_label owner;
          "scope_parent="
          ^ Option.fold ~none:"root"
              ~some:(fun parent -> scope_id_label parent)
              parent;
        ]
    | _ -> invalid_arg "Eta_signal: inconsistent dead signal scope"

  let dead_timer_fields = function
    | None -> []
    | Some timer ->
        let running =
          match timer.dead_timer_running_generation with
          | None -> "none"
          | Some generation -> string_of_int generation
        in
        [
          bool_field "timer_active" timer.dead_timer_active;
          "timer_running=" ^ running;
          bool_field "timer_cancel" timer.dead_timer_cancel;
          bool_field "timer_finished" timer.dead_timer_finished;
          "timer_generation=" ^ string_of_int timer.dead_timer_generation;
        ]

  let signal_label : type a. dot_options -> a signal -> string =
   fun options signal ->
    let fields =
      [ "kind=" ^ kind_name signal.kind; "signal_id=" ^ signal_id_label signal.id ]
    in
    let fields =
      if options.dot_state then fields @ signal_state_fields signal else fields
    in
    let fields =
      if options.dot_dynamic_scopes then fields @ signal_scope_fields signal
      else fields
    in
    let fields =
      if options.dot_timers then fields @ signal_timer_fields signal else fields
    in
    String.concat " " fields

  let dead_signal_label options dead =
    let fields =
      [
        "kind=" ^ dead.dead_kind;
        "signal_id=" ^ signal_id_label dead.dead_id;
        "tombstone=true";
      ]
    in
    let fields =
      if options.dot_state then fields @ dead_signal_state_fields dead
      else fields
    in
    let fields =
      if options.dot_dynamic_scopes then fields @ dead_signal_scope_fields dead
      else fields
    in
    let fields =
      if options.dot_timers then fields @ dead_timer_fields dead.dead_timer
      else fields
    in
    String.concat " " fields

  let observer_label ?missing_observed_signal_id (O observer) =
    let value_state_label, delivery_state_label =
      match observer.obs_state with
      | Observer_lifecycle.Registering live | Observer_lifecycle.Active live ->
          let snapshot = observer_current_snapshot live in
          ( Observer_core.Value.label snapshot.observer_value,
            Observer_core.Delivery.label snapshot.observer_delivery )
      | Observer_lifecycle.Disposed value | Observer_lifecycle.Invalid_scope value
        ->
          (Observer_core.Value.label value, "none")
    in
    let fields =
      [
        "observer:" ^ observer_id_label observer.obs_id;
        "observer_id=" ^ observer_id_label observer.obs_id;
        "state=" ^ Observer_lifecycle.label observer.obs_state;
        "value_state=" ^ value_state_label;
        "delivery_state=" ^ delivery_state_label;
      ]
      @
      match missing_observed_signal_id with
      | None -> []
      | Some id -> [ "missing_observed_signal_id=" ^ signal_id_label id ]
    in
    String.concat " " fields

  let observer_selected ~include_invalid (O observer as packed) =
    observer_active packed
    ||
    match observer.obs_state with
    | Observer_lifecycle.Invalid_scope _ -> include_invalid
    | Observer_lifecycle.Registering _ | Observer_lifecycle.Disposed _
    | Observer_lifecycle.Active _ -> false

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
    let buffer = Buffer.create 256 in
    let formatter = Format.formatter_of_buffer buffer in
    Format.fprintf formatter "digraph eta_signal {@.";
    List.iter
      (fun (P signal) ->
        if selected_live_signal signal then (
          Format.fprintf formatter "  %s [label=%S];@."
            (signal_id_label signal.id)
            (signal_label options signal);
          let emitted_edges = Hashtbl.create 8 in
          List.iter
            (fun (P dependency) ->
              if
                selected_id dependency.id
                && not (Hashtbl.mem emitted_edges dependency.id)
              then (
                Hashtbl.add emitted_edges dependency.id ();
                Format.fprintf formatter "  %s -> %s;@."
                  (dot_signal_id dependency.id)
                  (signal_id_label signal.id)))
            signal.dependencies))
      all_nodes;
    if include_dead_nodes then
      List.iter
        (fun tombstone ->
          Format.fprintf formatter "  %s [label=%S];@."
            (dead_signal_id_label tombstone.dead_id)
            (dead_signal_label options tombstone);
          let emitted_edges = Hashtbl.create 8 in
          List.iter
            (fun dependency_id ->
              if
                selected_id dependency_id
                && not (Hashtbl.mem emitted_edges dependency_id)
              then (
                Hashtbl.add emitted_edges dependency_id ();
                Format.fprintf formatter "  %s -> %s;@."
                  (dot_signal_id dependency_id)
                  (dead_signal_id_label tombstone.dead_id)))
            tombstone.dead_dependency_ids)
        graph.dead_nodes;
    if options.dot_observers then
      List.iter
        (fun (O observer as packed) ->
          if observer_selected ~include_invalid:include_dead_nodes packed then (
            let observed_signal_selected = selected_id observer.obs_signal.id in
            let missing_observed_signal_id =
              if include_dead_nodes && not observed_signal_selected then
                Some observer.obs_signal.id
              else None
            in
            Format.fprintf formatter "  %s [shape=box,label=%S];@."
              (observer_id_label observer.obs_id)
              (observer_label ?missing_observed_signal_id packed);
            if observed_signal_selected then
              Format.fprintf formatter
                "  %s -> %s [style=dashed,label=\"observes\"];@."
                (dot_signal_id observer.obs_signal.id)
                (observer_id_label observer.obs_id)))
        graph.observers;
    Format.fprintf formatter "}@.";
    Format.pp_print_flush formatter ();
    Buffer.contents buffer

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

    let timer_mark_stopped timer generation =
      with_graph_lane_sync (fun () ->
          Option.iter (set_timer_current_state timer)
            (Timer.mark_stopped (timer_effective_state timer) ~generation))

    let timer_mark_failed timer generation =
      with_graph_lane_sync (fun () ->
          Option.iter (set_timer_current_state timer)
            (Timer.mark_failed
               ~advance_generation:(checked_succ "timer generation")
               ~effective_state:(timer_effective_state timer)
               ~current_state:(timer_current_state timer) ~generation))

    let timer_cleanup_after_exit timer generation = function
      | Eta.Exit.Ok _ -> timer_mark_stopped timer generation
      | Eta.Exit.Error _ -> timer_mark_failed timer generation

    let timer_cleanup_failed_start timer generation = function
      | Eta.Exit.Ok _ -> Effect.unit
      | Eta.Exit.Error _ -> timer_mark_failed timer generation

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
    let catch_up_update_count = Timer.catch_up_update_count
    let catch_up_update_missed = Timer.catch_up_update_missed

    let timer_catch_up_batch_size = 64

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
      if remaining <= 0 then Effect.unit
      else
        let batch = min remaining timer_catch_up_batch_size in
        let missed =
          catch_up_update_missed update.timer_catch_up_policy missed
        in
        run_timer_update_batch timer generation batch update ~missed
        |> Effect.bind (function
             | `Stop -> Effect.unit
             | `Continue ->
                 let remaining = remaining - batch in
                 if remaining <= 0 then Effect.unit
                 else
                   Effect.yield
                   |> Effect.bind (fun () ->
                          run_timer_updates timer generation remaining update
                            ~missed))

    let rec timer_loop timer generation interval_ms next_due_ms update =
      timer_read_next_due timer generation next_due_ms
      |> Effect.bind (function
           | None -> Effect.unit
           | Some next_due_ms ->
               Effect.now
               |> Effect.bind (fun now_ms ->
                      let delay_ms = max 0 (next_due_ms - now_ms) in
                      Effect.sleep (Duration.ms delay_ms))
               |> Effect.bind (fun () ->
                      timer_read_next_due timer generation next_due_ms
                      |> Effect.bind (function
                           | None -> Effect.unit
                           | Some due_ms ->
                               Effect.now
                               |> Effect.bind (fun now_ms ->
                                      let missed =
                                        missed_cadences ~interval_ms
                                          ~next_due_ms:due_ms ~now_ms
                                      in
                                      let advanced_due_ms =
                                        advance_due due_ms interval_ms missed
                                      in
                                      let saturated_due =
                                        advanced_due_ms = max_int
                                        && now_ms >= advanced_due_ms
                                      in
                                      let updates =
                                        catch_up_update_count
                                          update.timer_catch_up_policy missed
                                      in
                                      Private_test_hooks.run
                                        After_timer_due_read_before_commit
                                      |> Effect.bind (fun () ->
                                             timer_advance_next_due timer
                                               generation ~expected:due_ms
                                               advanced_due_ms
                                             |> Effect.bind (function
                                                  | `Stop -> Effect.unit
                                                  | `Stale ->
                                                      timer_loop timer generation
                                                        interval_ms
                                                        advanced_due_ms update
                                                  | `Advanced ->
                                                      run_timer_updates timer
                                                        generation updates update
                                                        ~missed
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
                                                                               interval_ms
                                                                               advanced_due_ms
                                                                               update
                                                                         | `Stop ->
                                                                             Effect.unit)))))))))

    let attach_timer ?(update_on_start = false) ?(refresh_when_inactive = true)
        ?refresh_operation ~runtime_contract signal interval update =
      let timer =
        {
          timer_snapshot =
            Transaction.create_staged
              {
                timer_state = Timer_inactive 0;
                timer_on_demand_refresh_token = -1;
              };
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
                       let next_due_ms = add_ms_capped now_ms interval_ms in
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

    let timer_refresh_operation : type a.
        a var -> a timer_refresh_spec -> timer_refresh_operation =
     fun source -> function
      | Refresh_current_time -> Refresh_current_time_source source
      | Refresh_deadline deadline_ms -> Refresh_deadline_source (source, deadline_ms)
      | Refresh_interval interval_ms -> Refresh_interval_source (source, interval_ms)

    let make_timer_signal ?(update_on_start = false)
        ?(catch_up_policy = Catch_up_every_cadence)
        ?(refresh_when_inactive = true) ?equal ?refresh_on_demand initial interval
        ~runtime_contract update =
      let source = Var.create ?equal initial in
      let signal = Var.watch source in
      let refresh_operation =
        Option.map (timer_refresh_operation source) refresh_on_demand
      in
      attach_timer ~update_on_start ~refresh_when_inactive ?refresh_operation
        ~runtime_contract signal interval
        {
          timer_catch_up_policy = catch_up_policy;
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
                               make_timer_signal ~update_on_start:true
                                 ~equal:Int.equal
                                 ~catch_up_policy:Catch_up_once_per_wake
                                 ~refresh_on_demand:Refresh_current_time initial
                                 every ~runtime_contract
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
          make_timer_signal ~update_on_start:true
            ~catch_up_policy:Catch_up_once_per_wake ~equal:Bool.equal false every
            ~refresh_on_demand:(Refresh_deadline deadline_ms) ~runtime_contract
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
                          ~refresh_when_inactive:false
                          ~refresh_on_demand:(Refresh_interval interval_ms)
                          ~catch_up_policy:Catch_up_coalesced
                          ~runtime_contract
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
                        make_timer_signal initial every ~refresh_when_inactive:false
                          ~catch_up_policy:Catch_up_coalesced ~runtime_contract
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
                        make_timer_signal initial every ~refresh_when_inactive:false
                          ~runtime_contract
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

    let offer_bridge_update observer on_drop queue update =
      let delivery =
        {
          Stream_bridge.current_token =
            (fun () -> stream_delivery_token observer);
          acknowledge_sent =
            (fun token update ->
              acknowledge_stream_sent_delivery observer token update);
          acknowledge_drop =
            (fun token update ->
              acknowledge_stream_drop_delivery observer token update);
        }
      in
      let hooks =
        {
          Stream_bridge.after_try_send_before_ack =
            (fun () ->
              Private_test_hooks.run After_stream_try_send_before_ack);
          after_drop_before_ack =
            (fun () -> Private_test_hooks.run After_stream_drop_before_ack);
          on_closed_with_error =
            (fun err -> Effect.sync (fun () -> raise (Graph_error err)));
        }
      in
      Stream_bridge.offer ~queue ~delivery ~hooks ~on_drop update

    let observe ?(capacity = default_capacity) ?on_drop ?equal signal =
      Effect.sync (fun () -> Stream_bridge.create_stream ~capacity)
      |> Effect.flatten_result
      |> Effect.bind (fun (queue, stream) ->
             Observer.observe_with_hooks_callback ?equal
               ~on_finish:
                 [ Stream_bridge.observer_finish_hook ~queue ]
               signal
               (fun observer update ->
                 offer_bridge_update observer on_drop queue update)
             |> Effect.map_error (fun err -> (err :> stream_error))
             |> Effect.map (fun observer ->
                    (observer, stream)))
  end
end
