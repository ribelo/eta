module Effect = Eta.Effect
module Duration = Eta.Duration
module Queue = Eta.Queue
module Runtime_contract = Eta.Runtime_contract
module Sync_lock = Eta.Sync_lock

module type Observer_error = sig
  type t

  val pp : Format.formatter -> t -> unit
end

module Make (Observer_error : Observer_error) () = struct
  type observer_error = Observer_error.t

  type graph_error =
    [ `Ambiguous_scope
    | `Cycle
    | `Invalid_scope
    | `Reentrant_stabilization
    | `Reentrant_update ]

  type observer_read_error =
    [ `Disposed_observer
    | `Invalid_scope
    | `No_current_value
    | `Uninitialized_observer ]

  type stabilize_error = [ graph_error | `Observer_error of observer_error ]
  type time_error = [ graph_error | `Invalid_interval | `Past_deadline ]
  type stream_error = [ graph_error | `Invalid_capacity ]

  type 'a update =
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

  let pp_graph_error ppf = function
    | `Ambiguous_scope -> Format.pp_print_string ppf "ambiguous dynamic scope"
    | `Cycle -> Format.pp_print_string ppf "cycle detected"
    | `Invalid_scope -> Format.pp_print_string ppf "invalid dynamic scope"
    | `Reentrant_stabilization ->
        Format.pp_print_string ppf "reentrant stabilization"
    | `Reentrant_update ->
        Format.pp_print_string ppf "same-variable effectful update reentry"

  let pp_observer_read_error ppf = function
    | `Disposed_observer -> Format.pp_print_string ppf "disposed observer"
    | `Invalid_scope -> Format.pp_print_string ppf "invalid dynamic scope"
    | `No_current_value -> Format.pp_print_string ppf "no current observer value"
    | `Uninitialized_observer ->
        Format.pp_print_string ppf "uninitialized observer"

  let pp_stabilize_error ppf = function
    | #graph_error as err -> pp_graph_error ppf err
    | `Observer_error err ->
        Format.fprintf ppf "observer callback failed: %a" Observer_error.pp err

  let pp_time_error ppf = function
    | #graph_error as err -> pp_graph_error ppf err
    | `Invalid_interval -> Format.pp_print_string ppf "invalid interval"
    | `Past_deadline -> Format.pp_print_string ppf "deadline is in the past"

  let pp_stream_error ppf = function
    | #graph_error as err -> pp_graph_error ppf err
    | `Invalid_capacity ->
        Format.pp_print_string ppf "stream bridge capacity must be positive"

  let default_equal a b = a == b

  let saturating_succ value =
    if value = max_int then max_int else value + 1

  let counter_overflow name = invalid_arg ("Eta_signal: " ^ name ^ " overflow")

  let checked_succ name value =
    if value = max_int then counter_overflow name else value + 1

  type signal_id = Signal_id of int
  type scope_id = Scope_id of int
  type var_id = Var_id of int
  type observer_id = Observer_id of int

  let signal_id_int (Signal_id id) = id
  let scope_id_int (Scope_id id) = id
  let var_id_int (Var_id id) = id
  let observer_id_int (Observer_id id) = id

  let signal_id_label id = "s" ^ string_of_int (signal_id_int id)
  let dead_signal_id_label id = "dead_" ^ signal_id_label id
  let scope_id_label id = "sc" ^ string_of_int (scope_id_int id)
  let var_id_label id = "v" ^ string_of_int (var_id_int id)
  let observer_id_label id = "o" ^ string_of_int (observer_id_int id)

  let compare_observer_id left right =
    Int.compare (observer_id_int left) (observer_id_int right)

  type phase =
    | Not_stabilizing
    | Pure
    | Running_observers

  type scope = {
    scope_id : scope_id;
    scope_owner : signal_id;
    scope_parent : scope option;
    mutable scope_valid : bool;
    mutable scope_nodes : packed_signal list;
  }

  and packed_signal = P : 'a signal -> packed_signal

  and 'a signal = {
    id : signal_id;
    equal : 'a -> 'a -> bool;
    mutable kind : 'a kind;
    mutable value : 'a option;
    mutable staged : 'a option;
    mutable initialized : bool;
    mutable version : int;
    mutable dirty : bool;
    mutable dependency_versions : (signal_id * int) list;
    mutable staged_dependency_versions : (signal_id * int) list option;
    mutable dependencies : packed_signal list;
    mutable dependents : packed_signal list;
    mutable computing : bool;
    mutable seen_generation : int;
    mutable changed_seen : bool;
    mutable staged_generation : int;
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
    mutable source_value : 'a option;
    mutable inner : 'b signal option;
    mutable inner_scope : scope option;
    mutable staged_source_value : 'a option;
    mutable staged_inner : 'b signal option;
    mutable staged_inner_scope : scope option;
    mutable staged_bind_generation : int;
  }

  and packed_bind = B : ('a, 'b) bind -> packed_bind

  and 'a var = {
    var_id : var_id;
    var_equal : 'a -> 'a -> bool;
    mutable source_value : 'a;
    mutable graph_value : 'a;
    mutable staged_graph_value : 'a option;
    mutable staged_var_generation : int;
    mutable queued : bool;
    mutable updating : bool;
    mutable watchers : packed_signal list;
  }

  and packed_var = V : 'a var -> packed_var

  and observer_state =
    | Observer_registering
    | Observer_active
    | Observer_disposed
    | Observer_invalid_scope

  and 'a observer_value_state =
    | Observer_uninitialized
    | Observer_current of 'a
    | Observer_failed_without_current

  and 'a observer_delivery_state =
    | Observer_never_delivered
    | Observer_delivered of 'a
    | Observer_delivery_pending of int * 'a update
    | Observer_delivery_running of int * 'a update

  and 'a observer = {
    obs_id : observer_id;
    obs_signal : 'a signal;
    obs_equal : 'a -> 'a -> bool;
    obs_callback : 'a update -> (unit, observer_error) Effect.t;
    mutable obs_value_state : 'a observer_value_state;
    mutable obs_staged_current : 'a option;
    mutable obs_delivery_state : 'a observer_delivery_state;
    mutable obs_staged_delivery_state : 'a observer_delivery_state option;
    mutable obs_state : observer_state;
    mutable obs_staged_generation : int;
    mutable obs_after_ack : (int * (unit -> unit)) list;
    mutable obs_on_finish : (observer_state -> unit) list;
  }

  and packed_observer = O : 'a observer -> packed_observer

  and timer_state =
    | Timer_inactive of int
    | Timer_starting of int
    | Timer_running_uncancellable of int
    | Timer_running of int * (unit -> unit)
    | Timer_finished of int

  and timer_node = {
    mutable timer_state : timer_state;
    mutable timer_on_demand_refresh_token : int;
    timer_refresh_on_demand : (timer_node -> int -> unit) option;
    timer_start : 'err. timer_node -> (unit, 'err) Effect.t;
  }

  and 'err timer_start_attempt = {
    start_timer : timer_node;
    start_effect : (unit, 'err) Effect.t;
  }

  and timer_update = {
    timer_update : 'err. timer_node -> int -> (unit, 'err) Effect.t;
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
    source_timer_update : 'err. timer_node -> int -> 'a var -> (unit, 'err) Effect.t;
  }

  type disposal_hook = unit -> unit

  type event = E : int * 'a observer * 'a update -> event

  type pure_stabilize_result =
    | Pure_ok of disposal_hook list * event list
    | Pure_timer_refresh of disposal_hook list * timer_node list
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
  }

  type lane = {
    lane_lock : Sync_lock.t;
    lane_waiters : lane_waiter Stdlib.Queue.t;
    mutable lane_busy : bool;
    mutable lane_waiting : int;
    mutable lane_cancelled : int;
  }

  type graph = {
    lane : lane;
    owner_domain : Domain.id;
    mutable next_id : int;
    mutable next_scope_id : int;
    mutable phase : phase;
    mutable stabilization_id : int;
    mutable pending_vars : packed_var list;
    mutable staged_vars : packed_var list;
    mutable staged_binds : packed_bind list;
    mutable computed_nodes : packed_signal list;
    mutable staged_observers : packed_observer list;
    mutable pure_disposal_hooks : disposal_hook list;
    mutable observers : packed_observer list;
    mutable all_nodes : packed_signal list;
    mutable dead_nodes : dead_signal list;
    mutable current_scope : scope option;
    mutable pure_snapshot_commit_count : int;
    mutable callback_delivery_count : int;
    mutable recompute_count : int;
    mutable dynamic_scope_invalidations : int;
    mutable nodes_became_necessary : int;
    mutable nodes_became_unnecessary : int;
    mutable stream_bridge_drop_count : int;
    mutable necessary_node_ids : (signal_id, unit) Hashtbl.t;
    mutable next_timer_refresh_token : int;
  }

  exception Graph_error of graph_error

  let graph =
    {
      lane =
        {
          lane_lock = Sync_lock.create ();
          lane_waiters = Stdlib.Queue.create ();
          lane_busy = false;
          lane_waiting = 0;
          lane_cancelled = 0;
        };
      owner_domain = Domain.self ();
      next_id = 0;
      next_scope_id = 1;
      phase = Not_stabilizing;
      stabilization_id = 0;
      pending_vars = [];
      staged_vars = [];
      staged_binds = [];
      computed_nodes = [];
      staged_observers = [];
      pure_disposal_hooks = [];
      observers = [];
      all_nodes = [];
      dead_nodes = [];
      current_scope = None;
      pure_snapshot_commit_count = 0;
      callback_delivery_count = 0;
      recompute_count = 0;
      dynamic_scope_invalidations = 0;
      nodes_became_necessary = 0;
      nodes_became_unnecessary = 0;
      stream_bridge_drop_count = 0;
      necessary_node_ids = Hashtbl.create 16;
      next_timer_refresh_token = 0;
    }

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

  let rec take_waiting_waiter waiters =
    if Stdlib.Queue.is_empty waiters then None
    else
      let waiter = Stdlib.Queue.take waiters in
      match waiter.lane_state with
      | Lane_waiting -> Some waiter
      | Lane_granted | Lane_cancelled -> take_waiting_waiter waiters

  let compact_cancelled_lane_waiters_locked lane =
    if lane.lane_cancelled > 0 then (
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
        live)

  let grant_lane_waiter_locked waiter =
    waiter.lane_state <- Lane_granted;
    waiter

  let resolve_lane_waiter waiter =
    waiter.lane_contract.Runtime_contract.protect (fun () ->
        waiter.lane_contract.Runtime_contract.resolve_promise
          waiter.lane_resolver ())

  let release_lane_locked lane =
    match take_waiting_waiter lane.lane_waiters with
    | Some waiter ->
        lane.lane_waiting <- lane.lane_waiting - 1;
        Some (grant_lane_waiter_locked waiter)
    | None ->
        lane.lane_busy <- false;
        None

  let cancel_lane_waiter_locked lane waiter =
    match waiter.lane_state with
    | Lane_waiting ->
        waiter.lane_state <- Lane_cancelled;
        lane.lane_waiting <- lane.lane_waiting - 1;
        lane.lane_cancelled <- saturating_succ lane.lane_cancelled;
        compact_cancelled_lane_waiters_locked lane;
        None
    | Lane_granted ->
        waiter.lane_state <- Lane_cancelled;
        lane.lane_cancelled <- saturating_succ lane.lane_cancelled;
        release_lane_locked lane
    | Lane_cancelled -> None

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
      { lane_contract = contract; lane_resolver = resolver; lane_state = Lane_waiting }
    in
    Stdlib.Queue.push waiter lane.lane_waiters;
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
             with_lane_lock_during_cancel contract lane (fun () ->
                 release_lane_locked lane)
           else
             with_lane_lock_during_cancel contract lane (fun () ->
                 cancel_lane_waiter_locked lane waiter))
          |> Option.iter resolve_lane_waiter;
          raise exn)

  let leave_lane_sync lane =
    with_lane_lock lane (fun () -> release_lane_locked lane)
    |> Option.iter resolve_lane_waiter

  let graph_lane_depth_local : int Runtime_contract.local =
    Runtime_contract.create_local ()

  let release_graph_lane_sync owns_lane =
    if !owns_lane then (
      owns_lane := false;
      leave_lane_sync graph.lane)

  let with_graph_lane_sync f =
    Effect.Expert.make ~leaf_name:"Eta_signal.with_graph_lane_sync" (fun context ->
        let contract = Effect.Expert.contract context in
        let lane_depth =
          Option.value
            (contract.Runtime_contract.local_get graph_lane_depth_local)
            ~default:0
        in
        if lane_depth > 0 then
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
            let release_graph_lane =
              Effect.sync (fun () -> release_graph_lane_sync owns_lane)
            in
            contract.Runtime_contract.local_with_binding graph_lane_depth_local 1
              (fun () ->
                Effect.Expert.eval context
                  (Effect.sync f
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

  let next_signal_id () = Signal_id (next_id ())
  let next_var_id () = Var_id (next_id ())
  let next_observer_id () = Observer_id (next_id ())

  let new_scope owner =
    let id = graph.next_scope_id in
    graph.next_scope_id <- checked_succ "scope id" id;
    {
      scope_id = Scope_id id;
      scope_owner = owner.id;
      scope_parent = owner.scope;
      scope_valid = true;
      scope_nodes = [];
    }

  let current_generation () = graph.stabilization_id

  let remove_dependent child parent =
    child.dependents <-
      List.filter (fun (P candidate) -> candidate.id <> parent.id) child.dependents

  let detach_dependency parent child =
    remove_dependent child parent;
    parent.dependencies <-
      List.filter (fun (P candidate) -> candidate.id <> child.id) parent.dependencies

  let has_dependency parent child =
    List.exists (fun (P candidate) -> candidate.id = child.id) parent.dependencies

  let has_dependent child parent =
    List.exists (fun (P candidate) -> candidate.id = parent.id) child.dependents

  let attach_dependency parent child =
    if not (has_dependent child parent) then
      child.dependents <- P parent :: child.dependents;
    if not (has_dependency parent child) then
      parent.dependencies <- P child :: parent.dependencies

  let attach_packed_dependency parent (P child) =
    attach_dependency parent child

  let mark_self_dirty (P signal) = signal.dirty <- true

  let remove_var_watcher source signal =
    source.watchers <-
      List.filter
        (fun (P candidate) -> candidate.id <> signal.id)
        source.watchers

  let remember_staged_var (V var as packed) =
    let generation = current_generation () in
    if var.staged_var_generation <> generation then (
      var.staged_var_generation <- generation;
      graph.staged_vars <- packed :: graph.staged_vars)

  let stage_var_graph_value var value =
    remember_staged_var (V var);
    var.staged_graph_value <- Some value

  let effective_var_value var =
    if var.staged_var_generation = current_generation () then
      match var.staged_graph_value with
      | Some value -> value
      | None -> var.graph_value
    else var.graph_value

  let remember_computed (P signal as packed) =
    let generation = current_generation () in
    if signal.computed_generation <> generation then (
      signal.computed_generation <- generation;
      graph.computed_nodes <- packed :: graph.computed_nodes)

  let stage_signal signal value =
    let generation = current_generation () in
    if signal.staged_generation <> generation then signal.staged <- None;
    signal.staged_generation <- generation;
    signal.staged <- Some value

  let effective_signal_version signal =
    if signal.staged_generation = current_generation () then
      match signal.staged with
      | Some _ -> checked_succ "signal version" signal.version
      | None -> signal.version
    else signal.version

  let dependency_versions dependencies =
    List.map
      (fun (P signal) -> (signal.id, effective_signal_version signal))
      dependencies

  let dependencies_changed signal dependencies =
    signal.dependency_versions <> dependency_versions dependencies

  let stage_dependency_versions signal dependencies =
    let generation = current_generation () in
    if signal.staged_generation <> generation then signal.staged <- None;
    signal.staged_generation <- generation;
    signal.staged_dependency_versions <- Some (dependency_versions dependencies)

  let effective_signal_value signal =
    if signal.staged_generation = current_generation () then
      match signal.staged with
      | Some value -> value
      | None -> (
          match signal.value with
          | Some value -> value
          | None -> raise (Graph_error `Invalid_scope))
    else
      match signal.value with
      | Some value -> value
      | None -> raise (Graph_error `Invalid_scope)

  let remember_staged_observer (O observer as packed) =
    let generation = current_generation () in
    if observer.obs_staged_generation <> generation then (
      observer.obs_staged_generation <- generation;
      graph.staged_observers <- packed :: graph.staged_observers)

  let stage_observer_current observer value =
    remember_staged_observer (O observer);
    observer.obs_staged_current <- Some value

  let stage_observer_delivery_state observer state =
    remember_staged_observer (O observer);
    observer.obs_staged_delivery_state <- Some state

  let observer_active (O observer) =
    match observer.obs_state with
    | Observer_active -> true
    | Observer_registering | Observer_disposed | Observer_invalid_scope -> false

  let observer_demands_signal (O observer) =
    match observer.obs_state with
    | Observer_registering | Observer_active -> true
    | Observer_disposed | Observer_invalid_scope -> false

  let remove_observer observer =
    graph.observers <-
      List.filter
        (fun (O candidate) -> candidate.obs_id <> observer.obs_id)
        graph.observers

  let take_observer_finish_hooks observer state =
    let hooks = observer.obs_on_finish in
    observer.obs_on_finish <- [];
    List.map (fun hook () -> hook state) hooks

  let clear_observer_delivery observer =
    observer.obs_delivery_state <- Observer_never_delivered;
    observer.obs_staged_delivery_state <- None;
    observer.obs_after_ack <- []

  let finish_observer_unlocked observer state =
    match (observer.obs_state, state) with
    | Observer_registering, Observer_disposed ->
        clear_observer_delivery observer;
        observer.obs_state <- state;
        remove_observer observer;
        take_observer_finish_hooks observer state
    | Observer_registering, Observer_invalid_scope ->
        clear_observer_delivery observer;
        observer.obs_state <- state;
        take_observer_finish_hooks observer state
    | Observer_active, Observer_disposed ->
        clear_observer_delivery observer;
        observer.obs_state <- state;
        remove_observer observer;
        take_observer_finish_hooks observer state
    | Observer_active, Observer_invalid_scope ->
        clear_observer_delivery observer;
        observer.obs_state <- state;
        take_observer_finish_hooks observer state
    | Observer_invalid_scope, Observer_disposed ->
        clear_observer_delivery observer;
        observer.obs_state <- state;
        remove_observer observer;
        []
    | _, (Observer_registering | Observer_active) ->
        invalid_arg
          "Eta_signal: observer finish target cannot be registering or active"
    | Observer_disposed, _ | Observer_invalid_scope, Observer_invalid_scope ->
        []

  let dispose_observer_unlocked observer =
    finish_observer_unlocked observer Observer_disposed

  let invalidate_observer_unlocked observer =
    finish_observer_unlocked observer Observer_invalid_scope

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
    match graph.phase with
    | Not_stabilizing -> graph.current_scope
    | Pure -> (
        match graph.current_scope with
        | Some scope when scope.scope_valid -> Some scope
        | _ -> raise (Graph_error `Ambiguous_scope))
    | Running_observers -> raise (Graph_error `Ambiguous_scope)

  let add_to_scope scope signal =
    match scope with
    | None -> ()
    | Some scope -> scope.scope_nodes <- P signal :: scope.scope_nodes

  let validate_dependency (P signal) =
    if not signal.valid then raise (Graph_error `Invalid_scope)

  let rec scope_is_ancestor ~ancestor scope =
    ancestor == scope
    ||
    match scope.scope_parent with
    | None -> false
    | Some parent -> scope_is_ancestor ~ancestor parent

  let validate_bind_inner_scope scope inner =
    let seen = Hashtbl.create 16 in
    let rec visit (P signal) =
      if not signal.valid then raise (Graph_error `Invalid_scope);
      if not (Hashtbl.mem seen signal.id) then (
        Hashtbl.add seen signal.id ();
        (match signal.scope with
         | None -> ()
         | Some signal_scope ->
             if
               signal_scope.scope_valid
               && scope_is_ancestor ~ancestor:signal_scope scope
             then ()
             else raise (Graph_error `Invalid_scope));
        List.iter visit signal.dependencies)
    in
    visit (P inner)

  let timer_state_generation = function
    | Timer_inactive generation
    | Timer_starting generation
    | Timer_running_uncancellable generation
    | Timer_running (generation, _)
    | Timer_finished generation ->
        generation

  let timer_generation timer = timer_state_generation timer.timer_state

  let timer_state_label = function
    | Timer_inactive _ -> "inactive"
    | Timer_starting _ -> "starting"
    | Timer_running_uncancellable _ -> "running_uncancellable"
    | Timer_running _ -> "running"
    | Timer_finished _ -> "finished"

  let timer_active timer =
    match timer.timer_state with
    | Timer_starting _ | Timer_running_uncancellable _ | Timer_running _ ->
        true
    | Timer_inactive _ | Timer_finished _ -> false

  let timer_finished timer =
    match timer.timer_state with
    | Timer_finished _ -> true
    | Timer_inactive _ | Timer_starting _ | Timer_running_uncancellable _
    | Timer_running _ ->
        false

  let timer_can_refresh_on_demand token timer =
    Option.is_some timer.timer_refresh_on_demand
    && timer.timer_on_demand_refresh_token <> token
    && (not (timer_active timer))
    && not (timer_finished timer)

  let timer_running_generation timer =
    match timer.timer_state with
    | Timer_running_uncancellable generation | Timer_running (generation, _) ->
        Some generation
    | Timer_inactive _ | Timer_starting _ | Timer_finished _ -> None

  let timer_has_cancel timer =
    match timer.timer_state with
    | Timer_running (_, _) -> true
    | Timer_inactive _ | Timer_starting _ | Timer_running_uncancellable _
    | Timer_finished _ ->
        false

  let timer_running_current timer generation =
    match timer.timer_state with
    | Timer_running_uncancellable running_generation
    | Timer_running (running_generation, _) ->
        running_generation = generation
    | Timer_inactive _ | Timer_starting _ | Timer_finished _ -> false

  let timer_invalidate_generation_unlocked timer =
    let generation = checked_succ "timer generation" (timer_generation timer) in
    timer.timer_state <- Timer_inactive generation

  let timer_mark_unneeded_unlocked ?(cancel_running = true) timer =
    match timer.timer_state with
    | Timer_inactive _ | Timer_finished _ -> []
    | Timer_starting _ | Timer_running_uncancellable _ ->
        timer_invalidate_generation_unlocked timer;
        []
    | Timer_running (_, cancel) ->
        timer_invalidate_generation_unlocked timer;
        if cancel_running then [ cancel ] else []

  let timer_rollback_unclaimed_start_unlocked timer =
    match timer.timer_state with
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
        value = None;
        staged = None;
        initialized = false;
        version = 0;
        dirty;
        dependency_versions = [];
        staged_dependency_versions = None;
        dependencies = [];
        dependents = [];
        computing = false;
        seen_generation = -1;
        changed_seen = false;
        staged_generation = -1;
        computed_generation = -1;
        scope;
        valid = true;
        timer = None;
      }
    in
    List.iter (attach_packed_dependency signal) dependencies;
    add_to_scope scope signal;
    graph.all_nodes <- P signal :: graph.all_nodes;
    signal

  let new_const ?equal value =
    let signal = new_signal ?equal ~dirty:false (Const value) [] in
    signal.value <- Some value;
    signal.initialized <- true;
    signal

  let prune_invalid_nodes_unlocked () =
    graph.all_nodes <-
      List.filter (fun (P signal) -> signal.valid) graph.all_nodes

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
          ( Some scope.scope_id,
            Some scope.scope_owner,
            Option.map (fun parent -> parent.scope_id) scope.scope_parent,
            Some scope.scope_valid )
    in
    {
      dead_id = signal.id;
      dead_kind = kind_name signal.kind;
      dead_initialized = signal.initialized;
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
    if scope.scope_valid then (
      scope.scope_valid <- false;
      graph.dynamic_scope_invalidations <-
        saturating_succ graph.dynamic_scope_invalidations;
      let hooks = List.concat_map invalidate_node scope.scope_nodes in
      scope.scope_nodes <- [];
      if prune then prune_invalid_nodes_unlocked ();
      hooks)
    else []

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
            match bind.inner_scope with
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
        source_value = None;
        inner = None;
        inner_scope = None;
        staged_source_value = None;
        staged_inner = None;
        staged_inner_scope = None;
        staged_bind_generation = -1;
      }
    in
    let signal = new_signal ?equal (Bind bind) [ P source ] in
    bind.owner <- Some signal;
    signal

  let current_or_raise signal =
    match signal.value with
    | Some value -> value
    | None -> raise (Graph_error `Invalid_scope)

  let clear_signal_staging signal =
    signal.staged <- None;
    signal.staged_dependency_versions <- None

  let commit_signal (P signal) =
    if not signal.valid then (
      if signal.staged_generation = current_generation () then
        clear_signal_staging signal)
    else (
      if signal.staged_generation = current_generation () then (
        (match signal.staged with
         | None -> ()
         | Some value ->
             let next_version = checked_succ "signal version" signal.version in
             signal.value <- Some value;
             signal.initialized <- true;
             signal.version <- next_version);
        (match signal.staged_dependency_versions with
         | None -> ()
         | Some dependency_versions ->
             signal.dependency_versions <- dependency_versions);
        clear_signal_staging signal);
      signal.dirty <- false)

  let rollback_signal (P signal) =
    if signal.staged_generation = current_generation () then (
      clear_signal_staging signal)

  let commit_var (V var) =
    if var.staged_var_generation = current_generation () then (
      (match var.staged_graph_value with
       | None -> ()
       | Some value -> var.graph_value <- value);
      var.staged_graph_value <- None)

  let rollback_var (V var) =
    if var.staged_var_generation = current_generation () then
      var.staged_graph_value <- None

  let remember_staged_bind (B bind as packed) =
    let generation = current_generation () in
    if bind.staged_bind_generation <> generation then (
      bind.staged_bind_generation <- generation;
      graph.staged_binds <- packed :: graph.staged_binds)

  let stage_bind_switch bind source_value inner scope =
    remember_staged_bind (B bind);
    bind.staged_source_value <- Some source_value;
    bind.staged_inner <- Some inner;
    bind.staged_inner_scope <- Some scope

  let bind_effective_source_value bind =
    if bind.staged_bind_generation = current_generation () then
      bind.staged_source_value
    else bind.source_value

  let bind_effective_inner bind =
    if bind.staged_bind_generation = current_generation () then bind.staged_inner
    else bind.inner

  let clear_staged_bind bind =
    bind.staged_source_value <- None;
    bind.staged_inner <- None;
    bind.staged_inner_scope <- None

  let commit_bind (B bind) =
    if bind.staged_bind_generation = current_generation () then (
      let disposal_hooks =
        match
          ( bind.owner,
            bind.staged_source_value,
            bind.staged_inner,
            bind.staged_inner_scope )
        with
        | Some owner, Some source_value, Some inner, Some scope ->
            (match bind.inner with
             | None -> ()
             | Some old_inner -> detach_dependency owner old_inner);
            let hooks =
              match bind.inner_scope with
              | None -> []
              | Some old_scope -> invalidate_scope old_scope
            in
            bind.source_value <- Some source_value;
            bind.inner <- Some inner;
            bind.inner_scope <- Some scope;
            attach_dependency owner inner;
            hooks
        | _ -> raise (Graph_error `Invalid_scope)
      in
      clear_staged_bind bind;
      disposal_hooks)
    else []

  let rollback_bind (B bind) =
    if bind.staged_bind_generation = current_generation () then (
      let disposal_hooks =
        match bind.staged_inner_scope with
        | None -> []
        | Some scope -> invalidate_scope scope
      in
      clear_staged_bind bind;
      disposal_hooks)
    else []

  let collect_scope_invalidations_into seen collected scope =
    let rec visit_scope scope =
      if scope.scope_valid then List.iter visit scope.scope_nodes
    and visit (P signal as packed) =
      if signal.valid && not (Hashtbl.mem seen signal.id) then (
        Hashtbl.add seen signal.id ();
        collected := packed :: !collected;
        List.iter visit signal.dependents;
        match signal.kind with
        | Bind bind -> Option.iter visit_scope bind.inner_scope
        | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _
        | Map6 _ | Map7 _ | Map8 _ | Map9 _ | All _ ->
            ())
    in
    visit_scope scope

  let preflight_timer_stop timer =
    if timer_active timer || Option.is_some (timer_running_generation timer)
       || timer_has_cancel timer
    then ignore (checked_succ "timer generation" (timer_generation timer) : int)

  let preflight_staged_bind_commit seen collected (B bind) =
    if bind.staged_bind_generation = current_generation () then
      match
        ( bind.owner,
          bind.staged_source_value,
          bind.staged_inner,
          bind.staged_inner_scope )
      with
      | Some _, Some _, Some _, Some _ ->
          Option.iter
            (collect_scope_invalidations_into seen collected)
            bind.inner_scope
      | _ -> raise (Graph_error `Invalid_scope)

  let preflight_signal_commit invalidated_ids (P signal) =
    if
      signal.valid
      && not (Hashtbl.mem invalidated_ids signal.id)
      && signal.staged_generation = current_generation ()
    then
      match signal.staged with
      | None -> ()
      | Some _ -> ignore (checked_succ "signal version" signal.version : int)

  let preflight_commit_staging () =
    let invalidated_ids = Hashtbl.create 16 in
    let invalidated_nodes = ref [] in
    List.iter
      (preflight_staged_bind_commit invalidated_ids invalidated_nodes)
      graph.staged_binds;
    List.iter
      (fun (P signal) -> Option.iter preflight_timer_stop signal.timer)
      !invalidated_nodes;
    List.iter (preflight_signal_commit invalidated_ids) graph.computed_nodes

  let clear_observer_staging observer =
    observer.obs_staged_current <- None;
    observer.obs_staged_delivery_state <- None

  let commit_observer (O observer) =
    if not (observer_active (O observer)) then (
      if observer.obs_staged_generation = current_generation () then
        clear_observer_staging observer)
    else if observer.obs_staged_generation = current_generation () then (
      (match observer.obs_staged_current with
       | None -> ()
       | Some value ->
           observer.obs_value_state <- Observer_current value);
      (match observer.obs_staged_delivery_state with
       | None -> ()
       | Some state -> observer.obs_delivery_state <- state);
      clear_observer_staging observer)

  let rollback_observer (O observer) =
    if observer.obs_staged_generation = current_generation () then (
      clear_observer_staging observer)

  let remember_pure_disposal_hooks hooks =
    graph.pure_disposal_hooks <- hooks @ graph.pure_disposal_hooks

  let reset_staging () =
    List.iter rollback_signal graph.computed_nodes;
    List.iter rollback_var graph.staged_vars;
    let disposal_hooks =
      List.concat_map rollback_bind graph.staged_binds @ graph.pure_disposal_hooks
    in
    List.iter rollback_observer graph.staged_observers;
    graph.computed_nodes <- [];
    graph.staged_vars <- [];
    graph.staged_binds <- [];
    graph.staged_observers <- [];
    graph.pure_disposal_hooks <- [];
    disposal_hooks

  let commit_staging () =
    preflight_commit_staging ();
    List.iter commit_var graph.staged_vars;
    let commit_hooks = List.concat_map commit_bind graph.staged_binds in
    remember_pure_disposal_hooks commit_hooks;
    List.iter commit_signal graph.computed_nodes;
    List.iter commit_observer graph.staged_observers;
    let disposal_hooks = graph.pure_disposal_hooks in
    graph.computed_nodes <- [];
    graph.staged_vars <- [];
    graph.staged_binds <- [];
    graph.staged_observers <- [];
    graph.pure_disposal_hooks <- [];
    graph.pure_snapshot_commit_count <-
      saturating_succ graph.pure_snapshot_commit_count;
    disposal_hooks

  let requeue_if_needed (V var as packed) =
    if not var.queued then (
      var.queued <- true;
      graph.pending_vars <- packed :: graph.pending_vars)

  let mark_failed_without_current (O observer) =
    match observer.obs_value_state with
    | Observer_uninitialized ->
        observer.obs_value_state <- Observer_failed_without_current
    | Observer_current _ | Observer_failed_without_current -> ()

  let rollback_pure observers pending_at_start =
    let disposal_hooks = reset_staging () in
    List.iter mark_failed_without_current observers;
    List.iter requeue_if_needed pending_at_start;
    graph.phase <- Not_stabilizing;
    disposal_hooks

  let restart_pure pending_at_start =
    let disposal_hooks = reset_staging () in
    List.iter requeue_if_needed pending_at_start;
    graph.phase <- Not_stabilizing;
    disposal_hooks

  let next_timer_refresh_token_unlocked () =
    let token = graph.next_timer_refresh_token in
    graph.next_timer_refresh_token <-
      checked_succ "timer refresh token" graph.next_timer_refresh_token;
    token

  let refresh_on_demand_timer_sources token timers =
    Effect.now
    |> Effect.bind (fun now_ms ->
           with_graph_lane_sync (fun () ->
               List.iter
                 (fun timer ->
                   if timer_can_refresh_on_demand token timer then (
                     timer.timer_on_demand_refresh_token <- token;
                     match timer.timer_refresh_on_demand with
                     | None -> ()
                     | Some refresh -> refresh timer now_ms))
                 timers))

  let stage_pending_var (V var) =
    if not (var.var_equal var.graph_value var.source_value) then (
      stage_var_graph_value var var.source_value;
      List.iter mark_self_dirty var.watchers)

  let rec compute : type a. a signal -> a * bool =
   fun signal ->
    if not signal.valid then raise (Graph_error `Invalid_scope);
    let generation = current_generation () in
    if signal.seen_generation = generation then
      (effective_signal_value signal, signal.changed_seen)
    else if signal.computing then raise (Graph_error `Cycle)
    else (
      signal.computing <- true;
      match
        Fun.protect
          ~finally:(fun () -> signal.computing <- false)
          (fun () -> compute_uncached signal)
      with
      | value, changed ->
          signal.seen_generation <- generation;
          signal.changed_seen <- changed;
          (value, changed))

  and compute_uncached : type a. a signal -> a * bool =
   fun signal ->
    remember_computed (P signal);
    let recompute value =
      graph.recompute_count <- saturating_succ graph.recompute_count;
      let changed =
        (not signal.initialized)
        ||
        match signal.value with
        | None -> true
        | Some old_value -> not (signal.equal old_value value)
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
    match signal.kind with
    | Const value ->
        if signal.dirty || not signal.initialized then recompute value else use_cached ()
    | Var var ->
        if signal.dirty || not signal.initialized then
          recompute (effective_var_value var)
        else use_cached ()
    | Map (a, f) ->
        let av, ac = compute a in
        let dependencies = [ P a ] in
        if
          signal.dirty || ac || dependency_changed dependencies
          || not signal.initialized
        then recompute_with_dependencies dependencies (f av)
        else use_cached ()
    | Map2 (a, b, f) ->
        let av, ac = compute a in
        let bv, bc = compute b in
        let dependencies = [ P a; P b ] in
        if
          signal.dirty || ac || bc || dependency_changed dependencies
          || not signal.initialized
        then recompute_with_dependencies dependencies (f av bv)
        else use_cached ()
    | Map3 (a, b, c, f) ->
        let av, ac = compute a in
        let bv, bc = compute b in
        let cv, cc = compute c in
        let dependencies = [ P a; P b; P c ] in
        if
          signal.dirty || ac || bc || cc || dependency_changed dependencies
          || not signal.initialized
        then recompute_with_dependencies dependencies (f av bv cv)
        else use_cached ()
    | Map4 (a, b, c, d, f) ->
        let av, ac = compute a in
        let bv, bc = compute b in
        let cv, cc = compute c in
        let dv, dc = compute d in
        let dependencies = [ P a; P b; P c; P d ] in
        if
          signal.dirty || ac || bc || cc || dc || dependency_changed dependencies
          || not signal.initialized
        then recompute_with_dependencies dependencies (f av bv cv dv)
        else use_cached ()
    | Map5 (a, b, c, d, e, f) ->
        let av, ac = compute a in
        let bv, bc = compute b in
        let cv, cc = compute c in
        let dv, dc = compute d in
        let ev, ec = compute e in
        let dependencies = [ P a; P b; P c; P d; P e ] in
        if
          signal.dirty || ac || bc || cc || dc || ec || not signal.initialized
          || dependency_changed dependencies
        then recompute_with_dependencies dependencies (f av bv cv dv ev)
        else use_cached ()
    | Map6 (a, b, c, d, e, f_signal, f) ->
        let av, ac = compute a in
        let bv, bc = compute b in
        let cv, cc = compute c in
        let dv, dc = compute d in
        let ev, ec = compute e in
        let fv, fc = compute f_signal in
        let dependencies = [ P a; P b; P c; P d; P e; P f_signal ] in
        if
          signal.dirty || ac || bc || cc || dc || ec || fc
          || dependency_changed dependencies || not signal.initialized
        then recompute_with_dependencies dependencies (f av bv cv dv ev fv)
        else use_cached ()
    | Map7 (a, b, c, d, e, f_signal, g, f) ->
        let av, ac = compute a in
        let bv, bc = compute b in
        let cv, cc = compute c in
        let dv, dc = compute d in
        let ev, ec = compute e in
        let fv, fc = compute f_signal in
        let gv, gc = compute g in
        let dependencies = [ P a; P b; P c; P d; P e; P f_signal; P g ] in
        if
          signal.dirty || ac || bc || cc || dc || ec || fc || gc
          || dependency_changed dependencies || not signal.initialized
        then recompute_with_dependencies dependencies (f av bv cv dv ev fv gv)
        else use_cached ()
    | Map8 (a, b, c, d, e, f_signal, g, h, f) ->
        let av, ac = compute a in
        let bv, bc = compute b in
        let cv, cc = compute c in
        let dv, dc = compute d in
        let ev, ec = compute e in
        let fv, fc = compute f_signal in
        let gv, gc = compute g in
        let hv, hc = compute h in
        let dependencies =
          [ P a; P b; P c; P d; P e; P f_signal; P g; P h ]
        in
        if
          signal.dirty || ac || bc || cc || dc || ec || fc || gc || hc
          || dependency_changed dependencies || not signal.initialized
        then
          recompute_with_dependencies dependencies (f av bv cv dv ev fv gv hv)
        else use_cached ()
    | Map9 (a, b, c, d, e, f_signal, g, h, i, f) ->
        let av, ac = compute a in
        let bv, bc = compute b in
        let cv, cc = compute c in
        let dv, dc = compute d in
        let ev, ec = compute e in
        let fv, fc = compute f_signal in
        let gv, gc = compute g in
        let hv, hc = compute h in
        let iv, ic = compute i in
        let dependencies =
          [ P a; P b; P c; P d; P e; P f_signal; P g; P h; P i ]
        in
        if
          signal.dirty || ac || bc || cc || dc || ec || fc || gc || hc || ic
          || dependency_changed dependencies || not signal.initialized
        then
          recompute_with_dependencies dependencies (f av bv cv dv ev fv gv hv iv)
        else use_cached ()
    | All signals ->
        let values, changed =
          List.fold_right
            (fun child (values, changed) ->
              let value, child_changed = compute child in
              (value :: values, changed || child_changed))
            signals ([], false)
        in
        let dependencies = List.map (fun signal -> P signal) signals in
        if
          signal.dirty || changed || dependency_changed dependencies
          || not signal.initialized
        then recompute_with_dependencies dependencies values
        else use_cached ()
    | Bind bind ->
        let source_value, source_changed = compute bind.source in
        let needs_new_inner =
          match bind_effective_source_value bind with
          | None -> true
          | Some previous -> not (bind.source.equal previous source_value)
        in
        if needs_new_inner then (
          let scope = new_scope signal in
          let previous_scope = graph.current_scope in
          let inner, inner_value, changed, dependencies =
            try
              graph.current_scope <- Some scope;
              let inner =
                Fun.protect
                  ~finally:(fun () -> graph.current_scope <- previous_scope)
                  (fun () -> bind.selector source_value)
              in
              validate_bind_inner_scope scope inner;
              let inner_value, _inner_changed = compute inner in
              let dependencies = [ P bind.source; P inner ] in
              graph.recompute_count <- saturating_succ graph.recompute_count;
              let changed =
                (not signal.initialized)
                ||
                match signal.value with
                | None -> true
                | Some old_value -> not (signal.equal old_value inner_value)
              in
              (inner, inner_value, changed, dependencies)
            with exn ->
              let backtrace = Printexc.get_raw_backtrace () in
              graph.current_scope <- previous_scope;
              remember_pure_disposal_hooks (invalidate_scope scope);
              Printexc.raise_with_backtrace exn backtrace
          in
          stage_bind_switch bind source_value inner scope;
          stage_dependency_versions signal dependencies;
          if changed then stage_signal signal inner_value;
          (if changed then inner_value else current_or_raise signal), changed)
        else
          let inner =
            match bind_effective_inner bind with
            | Some inner -> inner
            | None -> raise (Graph_error `Invalid_scope)
          in
          let inner_value, inner_changed = compute inner in
          let dependencies = [ P bind.source; P inner ] in
          if
            signal.dirty || source_changed || inner_changed
            || dependency_changed dependencies || not signal.initialized
          then recompute_with_dependencies dependencies inner_value
          else use_cached ()

  let timer_finish_unlocked timer =
    let generation =
      if timer_active timer then
        checked_succ "timer generation" (timer_generation timer)
      else timer_generation timer
    in
    timer.timer_state <- Timer_finished generation

  let timer_has_current_start timer =
    match timer.timer_state with
    | Timer_running_uncancellable _ | Timer_running _ -> true
    | Timer_inactive _ | Timer_starting _ | Timer_finished _ -> false

  let timer_start_unlocked timer =
    if timer_finished timer || (timer_active timer && timer_has_current_start timer)
    then None
    else (
      let generation = checked_succ "timer generation" (timer_generation timer) in
      timer.timer_state <- Timer_starting generation;
      Some { start_timer = timer; start_effect = timer.timer_start timer })

  let timer_begin_start timer generation =
    with_graph_lane_sync (fun () ->
        match timer.timer_state with
        | Timer_starting starting_generation
          when starting_generation = generation ->
            timer.timer_state <- Timer_running_uncancellable generation;
            `Continue
        | Timer_inactive _ | Timer_starting _ | Timer_running_uncancellable _
        | Timer_running _ | Timer_finished _ ->
            `Stop)

  (* Pre-commit timer refresh must see staged bind inners. Committed demand
     counters and timer start/stop still use [signal.dependencies]. *)
  let effective_necessary_dependencies : type a. a signal -> packed_signal list =
   fun signal ->
    match signal.kind with
    | Bind bind ->
        P bind.source
        :: (match bind_effective_inner bind with
            | None -> []
            | Some inner -> [ P inner ])
    | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _ | Map6 _
    | Map7 _ | Map8 _ | Map9 _ | All _ ->
        signal.dependencies

  let collect_necessary_node_ids () =
    let seen = Hashtbl.create 16 in
    let rec visit (P signal) =
      if signal.valid && not (Hashtbl.mem seen signal.id) then (
        Hashtbl.add seen signal.id ();
        List.iter visit signal.dependencies)
    in
    List.iter
      (fun (O observer) ->
        if observer_demands_signal (O observer) then visit (P observer.obs_signal))
      graph.observers;
    seen

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
    let seen_nodes = Hashtbl.create 16 in
    let timers = Hashtbl.create 8 in
    let rec visit (P signal) =
      if signal.valid && not (Hashtbl.mem seen_nodes signal.id) then (
        Hashtbl.add seen_nodes signal.id ();
        Option.iter (fun timer -> Hashtbl.replace timers signal.id timer) signal.timer;
        List.iter visit signal.dependencies)
    in
    List.iter
      (fun (O observer) ->
        if observer_demands_signal (O observer) then visit (P observer.obs_signal))
      graph.observers;
    timers

  let effective_necessary_timers () =
    let seen_nodes = Hashtbl.create 16 in
    let timers = Hashtbl.create 8 in
    let rec visit (P signal) =
      if signal.valid && not (Hashtbl.mem seen_nodes signal.id) then (
        Hashtbl.add seen_nodes signal.id ();
        Option.iter (fun timer -> Hashtbl.replace timers signal.id timer) signal.timer;
        List.iter visit (effective_necessary_dependencies signal))
    in
    List.iter
      (fun (O observer) ->
        if observer_demands_signal (O observer) then visit (P observer.obs_signal))
      graph.observers;
    timers

  let on_demand_timer_refreshes token =
    Hashtbl.fold
      (fun _id timer refreshes ->
        if timer_can_refresh_on_demand token timer then timer :: refreshes
        else refreshes)
      (effective_necessary_timers ()) []

  let all_timers () =
    List.filter_map
      (fun (P signal) -> Option.map (fun timer -> (signal.id, timer)) signal.timer)
      graph.all_nodes

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

  let fail_with_pending_disposal_hooks hooks_ref effect =
    effect
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

  let refresh_timer_demand_unlocked () =
    let needed = necessary_timers () in
    let start_attempts = ref [] in
    let cancel_hooks = ref [] in
    List.iter
      (fun (id, timer) ->
        if Hashtbl.mem needed id then
          Option.iter
            (fun attempt -> start_attempts := attempt :: !start_attempts)
            (timer_start_unlocked timer)
        else
          cancel_hooks :=
            List.rev_append (timer_mark_unneeded_unlocked timer) !cancel_hooks)
      (all_timers ());
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

  let refresh_timer_demand () =
    Effect.acquire_use_release
      ~acquire:
        (with_graph_lane_sync (fun () ->
             let start_attempts, cancel_hooks = refresh_timer_demand_unlocked () in
             (start_attempts, ref cancel_hooks)))
      ~release:(fun (start_attempts, cancel_hooks_ref) ->
        rollback_unclaimed_timer_starts start_attempts
        |> Effect.bind (fun () ->
               run_pending_timer_cancel_hooks cancel_hooks_ref))
      (fun (start_attempts, cancel_hooks_ref) ->
        run_pending_timer_cancel_hooks cancel_hooks_ref
        |> Effect.bind (fun () -> run_timer_start_attempts start_attempts))

  let defect_with_pending_disposal_hooks hooks_ref exn backtrace =
    fail_with_pending_disposal_hooks hooks_ref
      (Effect.sync (fun () -> Printexc.raise_with_backtrace exn backtrace))

  let run_pending_stabilize_cleanup hooks_ref refresh_timers =
    if !refresh_timers then
      (Effect.sync (fun () -> refresh_timers := false)
       |> Effect.bind (fun () ->
              refresh_timer_demand ()
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
          |> Effect.bind (fun () -> refresh_timer_demand ())
        else Effect.unit)
       |> Effect.bind (fun () ->
              run_pending_disposal_hooks_as_finalizers hooks_ref))
      |> Effect.uninterruptible
    else Effect.unit

  let dispose_observer_effect observer =
    let hooks_ref = ref [] in
    let refresh_timers = ref false in
    with_graph_lane_sync
      (fun () ->
        if observer.obs_state <> Observer_disposed then (
          let hooks = dispose_observer_unlocked observer in
          hooks_ref := hooks;
          refresh_timers := true;
          update_necessity_counters_unlocked ())
        else ())
    |> Effect.bind (fun () ->
           run_pending_dispose_cleanup hooks_ref refresh_timers)
    |> Effect.on_exit (fun _exit ->
           run_pending_dispose_cleanup hooks_ref refresh_timers)

  let delivered_value = function
    | Initialized value -> value
    | Changed { new_value; _ } -> new_value

  let observer_delivery_base = function
    | Observer_never_delivered -> None
    | Observer_delivered value -> Some value
    | Observer_delivery_pending (_, Initialized _) -> None
    | Observer_delivery_pending (_, Changed { old_value; _ }) -> Some old_value
    | Observer_delivery_running (_, Initialized _) -> None
    | Observer_delivery_running (_, Changed { old_value; _ }) -> Some old_value

  let observer_delivery_pending = function
    | Observer_delivery_pending _ | Observer_delivery_running _ -> true
    | Observer_never_delivered | Observer_delivered _ -> false

  let collect_observer_event (O observer) =
    if not (observer_active (O observer)) then None
    else (
      let value, changed = compute observer.obs_signal in
      let event =
        match observer_delivery_base observer.obs_delivery_state with
        | None -> Some (Initialized value)
        | Some old_value ->
            if changed || observer_delivery_pending observer.obs_delivery_state
            then
              if observer.obs_equal old_value value then (
                stage_observer_delivery_state observer
                  (Observer_delivered value);
                None)
              else Some (Changed { old_value; new_value = value })
            else None
      in
      stage_observer_current observer value;
      Option.map
        (fun update -> E (current_generation (), observer, update))
        event)

  let mark_event_pending (E (token, observer, update)) =
    if observer_active (O observer) then (
      observer.obs_after_ack <- [];
      observer.obs_delivery_state <- Observer_delivery_pending (token, update)
    )

  let add_after_ack observer action =
    with_graph_lane_sync (fun () ->
        match observer.obs_delivery_state with
        | ( Observer_delivery_pending (token, _)
          | Observer_delivery_running (token, _) )
          when observer_active (O observer) ->
            observer.obs_after_ack <- (token, action) :: observer.obs_after_ack
        | Observer_never_delivered | Observer_delivered _
        | Observer_delivery_pending _ | Observer_delivery_running _ ->
            ())

  let run_after_ack observer token =
    let actions, remaining =
      List.partition
        (fun (action_token, _) -> action_token = token)
        observer.obs_after_ack
    in
    observer.obs_after_ack <- remaining;
    List.iter (fun (_, action) -> action ()) actions

  let acknowledge_event_delivery observer token update =
    with_graph_lane_sync (fun () ->
        match observer.obs_delivery_state with
        | ( Observer_delivery_pending (pending_token, _)
          | Observer_delivery_running (pending_token, _) )
          when observer_active (O observer) && pending_token = token ->
            observer.obs_delivery_state <- Observer_delivered (delivered_value update);
            run_after_ack observer pending_token
        | Observer_never_delivered | Observer_delivered _
        | Observer_delivery_pending _ | Observer_delivery_running _ ->
            ())

  let claim_event_delivery observer token =
    with_graph_lane_sync (fun () ->
        match observer.obs_delivery_state with
        | Observer_delivery_pending (pending_token, update)
          when observer_active (O observer) && pending_token = token ->
            observer.obs_delivery_state <-
              Observer_delivery_running (pending_token, update);
            true
        | Observer_never_delivered | Observer_delivered _
        | Observer_delivery_pending _ | Observer_delivery_running _ ->
            false)

  let release_event_delivery_claim observer token update =
    with_graph_lane_sync (fun () ->
        match observer.obs_delivery_state with
        | Observer_delivery_running (running_token, _)
          when observer_active (O observer) && running_token = token ->
            observer.obs_delivery_state <- Observer_delivery_pending (token, update)
        | Observer_never_delivered | Observer_delivered _
        | Observer_delivery_pending _ | Observer_delivery_running _ ->
            ())

  let begin_stabilize timer_refresh_token =
    if graph.phase <> Not_stabilizing then
      Pure_graph_error ([], `Reentrant_stabilization)
    else (
      let generation =
        checked_succ "stabilization generation" graph.stabilization_id
      in
      graph.phase <- Pure;
      graph.stabilization_id <- generation;
      graph.computed_nodes <- [];
      graph.staged_vars <- [];
      graph.staged_binds <- [];
      graph.staged_observers <- [];
      graph.pure_disposal_hooks <- [];
      let pending_at_start = List.rev graph.pending_vars in
      graph.pending_vars <- [];
      List.iter (fun (V var) -> var.queued <- false) pending_at_start;
      let observers =
        graph.observers
        |> List.filter observer_active
        |> List.sort (fun (O a) (O b) ->
               compare_observer_id a.obs_id b.obs_id)
      in
      try
        List.iter stage_pending_var pending_at_start;
        let events = List.filter_map collect_observer_event observers in
        match on_demand_timer_refreshes timer_refresh_token with
        | _ :: _ as refreshes ->
            let hooks = restart_pure pending_at_start in
            Pure_timer_refresh (hooks, refreshes)
        | [] ->
            let hooks = commit_staging () in
            List.iter mark_event_pending events;
            update_necessity_counters_unlocked ();
            graph.phase <- Running_observers;
            Pure_ok (hooks, events)
      with
      | Graph_error err ->
          let hooks = rollback_pure observers pending_at_start in
          Pure_graph_error (hooks, err)
      | exn ->
          let backtrace = Printexc.get_raw_backtrace () in
          let hooks = rollback_pure observers pending_at_start in
          Pure_defect (hooks, exn, backtrace))

  let finish_stabilize () =
    match graph.phase with
    | Running_observers | Pure -> graph.phase <- Not_stabilizing
    | Not_stabilizing -> ()

  let graph_error_of_die die =
    match die.Eta.Cause.exn with
    | Graph_error err -> Some err
    | _ -> None

  let rec observer_cause_to_stabilize = function
    | Eta.Cause.Fail err -> Eta.Cause.Fail (`Observer_error err)
    | Eta.Cause.Die die -> (
        match graph_error_of_die die with
        | Some err -> Eta.Cause.Fail (err :> stabilize_error)
        | None -> Eta.Cause.Die die)
    | Eta.Cause.Interrupt id -> Eta.Cause.Interrupt id
    | Eta.Cause.Sequential causes ->
        Eta.Cause.Sequential (List.map observer_cause_to_stabilize causes)
    | Eta.Cause.Concurrent causes ->
        Eta.Cause.Concurrent (List.map observer_cause_to_stabilize causes)
    | Eta.Cause.Finalizer cause -> Eta.Cause.Finalizer cause
    | Eta.Cause.Suppressed { primary; finalizer } ->
        Eta.Cause.Suppressed
          { primary = observer_cause_to_stabilize primary; finalizer }

  let run_observer_effect observer token update observer_eff =
    let delivered = ref false in
    let finish_delivery_after_error () =
      if !delivered then acknowledge_event_delivery observer token update
      else release_event_delivery_claim observer token update
    in
    ((Effect.Expert.make ~leaf_name:"eta_signal.observer" @@ fun context ->
      try
        match Effect.Expert.eval context observer_eff with
        | Eta.Exit.Ok () ->
            delivered := true;
            Eta.Exit.Ok ()
        | Eta.Exit.Error cause ->
            Eta.Exit.Error (observer_cause_to_stabilize cause)
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

  let construct_observer_effect observer update =
    Effect.sync (fun () ->
        try Ok (observer.obs_callback update)
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
                          (construct_observer_effect observer update
                           |> Effect.bind (fun observer_eff ->
                                  run_observer_effect observer token update
                                  observer_eff))
                          |> Effect.on_exit (function
                               | Eta.Exit.Ok _ -> Effect.unit
                               | Eta.Exit.Error _ ->
                                   release_event_delivery_claim observer token
                                     update)
                          |> Effect.bind (fun () -> run_events rest))))

  let begin_stabilize_with_pending_hooks timer_refresh_token hooks_ref
      finish_needed =
    let result = begin_stabilize timer_refresh_token in
    let hooks =
      match result with
      | Pure_ok (hooks, _) | Pure_timer_refresh (hooks, _)
      | Pure_graph_error (hooks, _)
      | Pure_defect (hooks, _, _) ->
          hooks
    in
    hooks_ref := hooks;
    (match result with
     | Pure_ok _ -> finish_needed := true
     | Pure_timer_refresh _ | Pure_graph_error _ | Pure_defect _ -> ());
    result

  let finish_stabilize_with_pending_cleanup hooks_ref refresh_timers
      finish_needed =
    run_pending_stabilize_cleanup hooks_ref refresh_timers
    |> Effect.on_exit (fun _exit ->
           if !finish_needed then with_graph_lane_sync finish_stabilize
           else Effect.unit)

  let stabilize =
    Effect.sync (fun () -> (ref [], ref false, ref false, ref None))
    |> Effect.bind
         (fun (hooks_ref, refresh_timers, finish_needed, timer_refresh_token) ->
           let get_timer_refresh_token () =
             match !timer_refresh_token with
             | Some token -> token
             | None ->
                 let token = next_timer_refresh_token_unlocked () in
                 timer_refresh_token := Some token;
                 token
           in
           let rec loop () =
             with_graph_lane_sync (fun () ->
                 let token = get_timer_refresh_token () in
                 (token, begin_stabilize_with_pending_hooks token hooks_ref
                           finish_needed))
             |> Effect.bind (function
                  | token, Pure_timer_refresh (_, timers) ->
                      run_pending_disposal_hooks_as_finalizers hooks_ref
                      |> Effect.bind (fun () ->
                             refresh_on_demand_timer_sources token timers)
                      |> Effect.bind loop
                  | _, Pure_graph_error (_, err) ->
                      graph_error_with_pending_disposal_hooks hooks_ref err
                  | _, Pure_defect (_, exn, backtrace) ->
                      defect_with_pending_disposal_hooks hooks_ref exn backtrace
                  | _, Pure_ok (_, events) ->
                      refresh_timers := true;
                      run_pending_stabilize_cleanup hooks_ref refresh_timers
                      |> Effect.bind (fun () -> run_events events)
                      |> Effect.bind mark_callback_delivery_complete)
           in
           loop ()
           |> Effect.on_exit (fun _exit ->
                  finish_stabilize_with_pending_cleanup hooks_ref refresh_timers
                    finish_needed))

  module Var = struct
    type 'a t = 'a var

    let create ?(equal = default_equal) value =
      {
        var_id = next_var_id ();
        var_equal = equal;
        source_value = value;
        graph_value = value;
        staged_graph_value = None;
        staged_var_generation = -1;
        queued = false;
        updating = false;
        watchers = [];
      }

    let value (source : 'a t) =
      ensure_graph_context ();
      source.source_value

    let watch (source : 'a t) =
      let signal = new_signal (Var source) [] in
      source.watchers <- P signal :: source.watchers;
      signal

    let queue_var (source : 'a t) =
      if not source.queued then (
        source.queued <- true;
        graph.pending_vars <- V source :: graph.pending_vars)

    let set_unlocked (source : 'a t) value =
      source.source_value <- value;
      queue_var source

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
              Ok source.source_value))
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

    let return_active_observer observer =
      with_graph_lane_sync (fun () ->
          match observer.obs_state with
          | Observer_registering ->
              observer.obs_state <- Observer_active;
              Ok observer
          | Observer_active -> Ok observer
          | Observer_invalid_scope | Observer_disposed -> Error `Invalid_scope)
      |> Effect.flatten_result

    let observe_with_hooks_callback ?(equal = default_equal) ?(on_finish = [])
        signal callback =
      with_graph_lane_sync (fun () ->
          if not signal.valid then Error `Invalid_scope
          else
            let rec observer =
              {
                obs_id = next_observer_id ();
                obs_signal = signal;
                obs_equal = equal;
                obs_callback = (fun update -> callback observer update);
                obs_value_state = Observer_uninitialized;
                obs_staged_current = None;
                obs_delivery_state = Observer_never_delivered;
                obs_staged_delivery_state = None;
                obs_state = Observer_registering;
                obs_staged_generation = -1;
                obs_after_ack = [];
                obs_on_finish = on_finish;
              }
            in
            graph.observers <- O observer :: graph.observers;
            update_necessity_counters_unlocked ();
            Ok observer)
      |> Effect.flatten_result
      |> Effect.bind (fun observer ->
             let transferred = ref false in
             (refresh_timer_demand ()
             |> Effect.bind (fun () -> return_active_observer observer)
             |> Effect.map (fun observer ->
                    transferred := true;
                    observer))
             |> Effect.on_exit (fun _exit ->
                    if !transferred then Effect.unit
                    else dispose_observer_effect observer))

    let observe_with_hooks ?equal ?on_finish signal callback =
      observe_with_hooks_callback ?equal ?on_finish signal
        (fun _observer update -> callback update)

    let observe ?equal signal callback = observe_with_hooks ?equal signal callback

    let read observer =
      with_graph_lane_sync (fun () ->
          match observer.obs_state with
          | Observer_registering -> Error `Uninitialized_observer
          | Observer_disposed -> Error `Disposed_observer
          | Observer_invalid_scope -> Error `Invalid_scope
          | Observer_active -> (
              match observer.obs_value_state with
              | Observer_current value -> Ok value
              | Observer_failed_without_current -> Error `No_current_value
              | Observer_uninitialized -> Error `Uninitialized_observer))
      |> Effect.flatten_result

    let unsafe_read_exn observer =
      ensure_graph_context ();
      match observer.obs_state with
      | Observer_registering ->
          invalid_arg "Eta_signal observer registration has not completed"
      | Observer_disposed -> invalid_arg "Eta_signal observer is disposed"
      | Observer_invalid_scope ->
          invalid_arg "Eta_signal observer scope is invalid"
      | Observer_active -> (
          match observer.obs_value_state with
          | Observer_current value -> value
          | Observer_uninitialized | Observer_failed_without_current ->
              invalid_arg "Eta_signal observer is not initialized")

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

  let active_observer_count () =
    List.fold_left
      (fun count observer ->
        if observer_active observer then saturating_succ count else count)
      0 graph.observers

  let invalid_observer_count () =
    List.fold_left
      (fun count (O observer) ->
        if observer.obs_state = Observer_invalid_scope then
          saturating_succ count
        else count)
      0 graph.observers

  let necessary_node_count () =
    Hashtbl.length (collect_necessary_node_ids ())

  let dead_node_count () = List.length graph.dead_nodes

  let live_dirty_node_count () =
    List.fold_left
      (fun count (P signal) ->
        if signal.valid && signal.dirty then saturating_succ count else count)
      0 graph.all_nodes

  let stats () =
    with_graph_lane_sync @@ fun () ->
    {
      pure_snapshot_commit_count = graph.pure_snapshot_commit_count;
      callback_delivery_count = graph.callback_delivery_count;
      total_node_count = List.length graph.all_nodes;
      active_observer_count = active_observer_count ();
      invalid_observer_count = invalid_observer_count ();
      necessary_node_count = necessary_node_count ();
      dead_node_count = dead_node_count ();
      live_dirty_node_count = live_dirty_node_count ();
      recompute_count = graph.recompute_count;
      dynamic_scope_invalidations = graph.dynamic_scope_invalidations;
      nodes_became_necessary = graph.nodes_became_necessary;
      nodes_became_unnecessary = graph.nodes_became_unnecessary;
      stream_bridge_drop_count = graph.stream_bridge_drop_count;
      lane_waiter_count = graph.lane.lane_waiting;
      lane_cancelled_waiter_count = graph.lane.lane_cancelled;
    }

  let record_stream_bridge_drop_unlocked () =
    graph.stream_bridge_drop_count <-
      saturating_succ graph.stream_bridge_drop_count

  let signal_selected :
      type a. dot_options -> (signal_id, unit) Hashtbl.t -> a signal -> bool =
   fun options necessary signal ->
    match options.dot_scope with
    | `Necessary -> Hashtbl.mem necessary signal.id
    | `All_valid -> signal.valid
    | `All_including_invalid -> true

  let bool_field name value = name ^ "=" ^ string_of_bool value

  let signal_state_fields : type a. a signal -> string list =
   fun signal ->
    let base =
      [
        bool_field "valid" signal.valid;
        bool_field "initialized" signal.initialized;
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
          match scope.scope_parent with
          | None -> "root"
          | Some parent -> scope_id_label parent.scope_id
        in
        [
          "scope="
          ^ scope_id_label scope.scope_id
          ^ ":"
          ^ (if scope.scope_valid then "valid" else "invalid");
          "scope_id=" ^ scope_id_label scope.scope_id;
          "scope_owner=" ^ signal_id_label scope.scope_owner;
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
          "timer_state=" ^ timer_state_label timer.timer_state;
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

  let observer_state_label = function
    | Observer_registering -> "registering"
    | Observer_active -> "active"
    | Observer_disposed -> "disposed"
    | Observer_invalid_scope -> "invalid_scope"

  let observer_value_state_label = function
    | Observer_uninitialized -> "uninitialized"
    | Observer_current _ -> "current"
    | Observer_failed_without_current -> "failed_without_current"

  let observer_delivery_state_label = function
    | Observer_never_delivered -> "never_delivered"
    | Observer_delivered _ -> "delivered"
    | Observer_delivery_pending _ -> "pending"
    | Observer_delivery_running _ -> "running"

  let observer_label (O observer) =
    String.concat " "
      [
        "observer:" ^ observer_id_label observer.obs_id;
        "observer_id=" ^ observer_id_label observer.obs_id;
        "state=" ^ observer_state_label observer.obs_state;
        "value_state=" ^ observer_value_state_label observer.obs_value_state;
        "delivery_state="
        ^ observer_delivery_state_label observer.obs_delivery_state;
      ]

  let observer_selected ~include_invalid (O observer as packed) =
    observer_active packed
    ||
    match observer.obs_state with
    | Observer_invalid_scope -> include_invalid
    | Observer_registering | Observer_disposed | Observer_active -> false

  let to_dot ?(options = default_dot_options) () =
    with_graph_lane_sync @@ fun () ->
    let necessary = collect_necessary_node_ids () in
    let selected signal = signal_selected options necessary signal in
    let include_dead_nodes =
      match options.dot_scope with
      | `All_including_invalid -> true
      | `Necessary | `All_valid -> false
    in
    let live_ids = Hashtbl.create 16 in
    let dead_ids = Hashtbl.create 16 in
    List.iter
      (fun (P signal) ->
        if selected signal then Hashtbl.replace live_ids signal.id ())
      graph.all_nodes;
    if include_dead_nodes then
      List.iter
        (fun tombstone -> Hashtbl.replace dead_ids tombstone.dead_id ())
        graph.dead_nodes;
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
        if selected signal then (
          Format.fprintf formatter "  %s [label=%S];@."
            (signal_id_label signal.id)
            (signal_label options signal);
          let emitted_edges = Hashtbl.create 8 in
          List.iter
            (fun (P dependency) ->
              if
                selected dependency
                && not (Hashtbl.mem emitted_edges dependency.id)
              then (
                Hashtbl.add emitted_edges dependency.id ();
                Format.fprintf formatter "  %s -> %s;@."
                  (signal_id_label dependency.id)
                  (signal_id_label signal.id)))
            signal.dependencies))
      graph.all_nodes;
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
            Format.fprintf formatter "  %s [shape=box,label=%S];@."
              (observer_id_label observer.obs_id)
              (observer_label packed);
            if selected_id observer.obs_signal.id then
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
      if Duration.to_ms duration <= 0 then Error `Invalid_interval else Ok ()

    let validate_future now deadline_ms =
      if deadline_ms <= now then Error `Past_deadline else Ok ()

    let validate_positive_duration duration =
      if Duration.to_ms duration <= 0 then Error `Past_deadline else Ok ()

    let install_timer_cancel timer generation cancel =
      with_graph_lane_sync (fun () ->
          match timer.timer_state with
          | Timer_running_uncancellable running_generation
          | Timer_running (running_generation, _)
            when running_generation = generation ->
              timer.timer_state <- Timer_running (generation, cancel);
              `Continue
          | Timer_inactive _ | Timer_starting _
          | Timer_running_uncancellable _ | Timer_running _ | Timer_finished _
            ->
              `Stop)

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
          if timer_running_current timer generation then
            timer.timer_state <- Timer_inactive generation)

    let timer_mark_failed timer generation =
      with_graph_lane_sync (fun () ->
          if timer_running_current timer generation then
            ignore
              (timer_mark_unneeded_unlocked ~cancel_running:false timer
                : (unit -> unit) list))

    let timer_cleanup_after_exit timer generation = function
      | Eta.Exit.Ok _ -> timer_mark_stopped timer generation
      | Eta.Exit.Error _ -> timer_mark_failed timer generation

    let timer_cleanup_failed_start timer generation = function
      | Eta.Exit.Ok _ -> Effect.unit
      | Eta.Exit.Error _ -> timer_mark_failed timer generation

    let timer_after_update_state timer generation =
      with_graph_lane_sync (fun () ->
          if timer_running_current timer generation then `Continue else `Stop)

    let timer_set_source timer generation (source : 'a var) value =
      with_graph_lane_sync (fun () ->
          if timer_running_current timer generation then (
            source.source_value <- value;
            Var.queue_var source;
            `Updated)
          else `Stopped)

    let add_ms_capped left right =
      if right <= 0 then left
      else if left > max_int - right then max_int
      else left + right

    let mul_ms_capped left right =
      if left <= 0 || right <= 0 then 0
      else if left > max_int / right then max_int
      else left * right

    let missed_cadences ~interval_ms ~next_due_ms ~now_ms =
      if now_ms < next_due_ms then 0
      else
        let elapsed = (now_ms - next_due_ms) / interval_ms in
        checked_succ "timer catch-up" elapsed

    let advance_due next_due_ms interval_ms missed =
      add_ms_capped next_due_ms (mul_ms_capped interval_ms missed)

    let timer_catch_up_batch_size = 64

    let rec run_timer_update_batch timer generation remaining update =
      if remaining <= 0 then Effect.pure `Continue
      else
        timer_after_update_state timer generation
        |> Effect.bind (function
             | `Stop -> Effect.pure `Stop
             | `Continue ->
                 Effect.sync (fun () -> update.timer_update timer generation)
                 |> Effect.bind (fun update_eff -> update_eff)
                 |> Effect.bind (fun () ->
                        run_timer_update_batch timer generation (remaining - 1)
                          update))

    let rec run_timer_updates timer generation remaining update =
      if remaining <= 0 then Effect.unit
      else
        let batch = min remaining timer_catch_up_batch_size in
        run_timer_update_batch timer generation batch update
        |> Effect.bind (function
             | `Stop -> Effect.unit
             | `Continue ->
                 let remaining = remaining - batch in
                 if remaining <= 0 then Effect.unit
                 else
                   Effect.yield
                   |> Effect.bind (fun () ->
                          run_timer_updates timer generation remaining update))

    let rec timer_loop timer generation interval_ms next_due_ms update =
      Effect.now
      |> Effect.bind (fun now_ms ->
             let delay_ms = max 0 (next_due_ms - now_ms) in
             Effect.sleep (Duration.ms delay_ms))
      |> Effect.bind (fun () ->
             Effect.now
             |> Effect.bind (fun now_ms ->
                    let missed =
                      missed_cadences ~interval_ms ~next_due_ms ~now_ms
                    in
                    let next_due_ms =
                      advance_due next_due_ms interval_ms missed
                    in
                    run_timer_updates timer generation missed update
                    |> Effect.bind (fun () ->
                           timer_after_update_state timer generation
                           |> Effect.bind (function
                                | `Continue ->
                                    timer_loop timer generation interval_ms
                                      next_due_ms update
                                | `Stop -> Effect.unit))))

    let attach_timer ?(update_on_start = false) ?refresh_on_demand signal
        interval update =
      let timer =
        {
          timer_state = Timer_inactive 0;
          timer_on_demand_refresh_token = -1;
          timer_refresh_on_demand = refresh_on_demand;
          timer_start =
            (fun timer ->
              let generation = timer_generation timer in
              let interval_ms = Duration.to_ms interval in
              let start_loop () =
                Effect.now
                |> Effect.bind (fun now_ms ->
                       let next_due_ms = add_ms_capped now_ms interval_ms in
                       Effect.daemon
                         (cancellable_timer_loop timer generation
                            (timer_loop timer generation interval_ms next_due_ms
                               update
                            |> Effect.on_exit
                                 (timer_cleanup_after_exit timer generation))))
              in
              let start =
                if update_on_start then
                  update.timer_update timer generation
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

    let make_timer_signal ?(update_on_start = false) ?equal ?refresh_on_demand
        initial interval update =
      let source = Var.create ?equal initial in
      let signal = Var.watch source in
      let refresh_on_demand =
        Option.map
          (fun refresh timer now_ms -> refresh source timer now_ms)
          refresh_on_demand
      in
      attach_timer ~update_on_start ?refresh_on_demand signal interval
        {
          timer_update =
            (fun timer generation ->
              update.source_timer_update timer generation source);
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
             Effect.now
             |> Effect.bind (fun initial ->
                    construct_timer_signal (fun () ->
                        make_timer_signal ~update_on_start:true ~equal:Int.equal
                          ~refresh_on_demand:(fun source _timer now_ms ->
                            Var.set_unlocked source now_ms)
                          initial every
                          {
                            source_timer_update =
                              (fun timer generation source ->
                                Effect.now
                                |> Effect.bind (fun now_ms ->
                                       timer_set_source timer generation source
                                         now_ms
                                       |> Effect.map (fun _ -> ())));
                          })))

    let construct_deadline_signal every deadline_ms =
      construct_timer_signal (fun () ->
          make_timer_signal ~update_on_start:true ~equal:Bool.equal false every
            ~refresh_on_demand:(fun source timer now_ms ->
              if now_ms >= deadline_ms then (
                Var.set_unlocked source true;
                timer_finish_unlocked timer)
              else Var.set_unlocked source false)
            {
              source_timer_update =
                (fun timer generation source ->
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
             Effect.now
             |> Effect.bind (fun now_ms ->
                    Effect.from_result (validate_future now_ms deadline_ms)
                    |> Effect.bind (fun () ->
                           construct_deadline_signal every deadline_ms)))

    let after ~every duration =
      Effect.sync (fun () ->
          match validate_interval every with
          | Error _ as error -> error
          | Ok () -> validate_positive_duration duration)
      |> Effect.flatten_result
      |> Effect.bind (fun () ->
             Effect.now
             |> Effect.bind (fun now_ms ->
                    let deadline_ms =
                      add_ms_capped now_ms (Duration.to_ms duration)
                    in
                    construct_deadline_signal every deadline_ms))

    let interval interval =
      Effect.sync (fun () -> validate_interval interval)
      |> Effect.flatten_result
      |> Effect.bind (fun () ->
             construct_timer_signal (fun () ->
                 make_timer_signal ~equal:Int.equal 0 interval
                   {
                     source_timer_update =
                       (fun timer generation source ->
                         Effect.sync (fun () ->
                             checked_succ "interval counter"
                               (Var.value source))
                         |> Effect.annotate ~key:"eta_signal.timer.kind"
                              ~value:"interval"
                         |> Effect.named "eta_signal.time.interval"
                         |> Effect.bind (fun next ->
                                timer_set_source timer generation source next
                                |> Effect.map (fun _ -> ())));
                   }))

    let step ~every ~initial f =
      Effect.sync (fun () -> validate_interval every)
      |> Effect.flatten_result
      |> Effect.bind (fun () ->
             construct_timer_signal (fun () ->
                 make_timer_signal initial every
                   {
                     source_timer_update =
                       (fun timer generation source ->
                         Effect.sync (fun () -> f (Var.value source))
                         |> Effect.annotate ~key:"eta_signal.timer.kind"
                              ~value:"step"
                         |> Effect.named "eta_signal.time.step"
                         |> Effect.bind (fun next ->
                                timer_set_source timer generation source next
                                |> Effect.map (fun _ -> ())));
                   }))
  end

  module Stream = struct
    let default_capacity = 1024

    let create_bridge_queue capacity =
      if capacity <= 0 then Error `Invalid_capacity
      else
        Ok
          (Queue.create
             ~overflow:(Queue.Drop_new { capacity })
             ())

    let report_dropped_update observer on_drop update =
      (match on_drop with
      | None -> Effect.unit
      | Some on_drop -> Effect.sync (fun () -> on_drop update))
      |> Effect.bind (fun () ->
             add_after_ack observer record_stream_bridge_drop_unlocked)

    let offer_bridge_update observer on_drop queue update =
      Queue.try_send queue update
      |> Effect.bind (function
           | `Sent | `Closed -> Effect.unit
           | `Dropped | `Full ->
               report_dropped_update observer on_drop update
           | `Closed_with_error err ->
               Effect.sync (fun () -> raise (Graph_error err)))

    let observe ?(capacity = default_capacity) ?on_drop ?equal signal =
      Effect.sync (fun () -> create_bridge_queue capacity)
      |> Effect.flatten_result
      |> Effect.bind (fun queue ->
             Observer.observe_with_hooks_callback ?equal
               ~on_finish:
                 [
                   (function
                   | Observer_disposed -> Queue.close queue
                   | Observer_invalid_scope ->
                       Queue.close_with_error queue `Invalid_scope
                   | Observer_registering
                   | Observer_active -> ());
                 ]
               signal
               (fun observer update ->
                 offer_bridge_update observer on_drop queue update)
             |> Effect.map_error (fun err -> (err :> stream_error))
             |> Effect.map (fun observer ->
                    (observer, Eta_stream.Stream.from_queue queue)))
  end
end
