module Effect = Eta.Effect
module Duration = Eta.Duration
module Queue = Eta.Queue
module Runtime_contract = Eta.Runtime_contract
module Schedule = Eta.Schedule
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
  type time_error = [ `Invalid_interval | `Past_deadline ]
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
    | `Invalid_interval -> Format.pp_print_string ppf "invalid interval"
    | `Past_deadline -> Format.pp_print_string ppf "deadline is in the past"

  let pp_stream_error ppf = function
    | #graph_error as err -> pp_graph_error ppf err
    | `Invalid_capacity ->
        Format.pp_print_string ppf "stream bridge capacity must be positive"

  let default_equal a b = a == b

  let saturating_succ value =
    if value = max_int then max_int else value + 1

  type signal_id = Signal_id of int
  type scope_id = Scope_id of int
  type var_id = Var_id of int
  type observer_id = Observer_id of int

  let signal_id_int (Signal_id id) = id
  let scope_id_int (Scope_id id) = id
  let var_id_int (Var_id id) = id
  let observer_id_int (Observer_id id) = id

  let signal_id_label id = "s" ^ string_of_int (signal_id_int id)
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
    | Observer_active
    | Observer_disposed
    | Observer_invalid_scope

  and 'a observer = {
    obs_id : observer_id;
    obs_signal : 'a signal;
    obs_equal : 'a -> 'a -> bool;
    obs_callback : 'a update -> (unit, observer_error) Effect.t;
    mutable obs_current : 'a option;
    mutable obs_staged_current : 'a option;
    mutable obs_initialized : bool;
    mutable obs_delivered_current : 'a option;
    mutable obs_staged_delivered_current : 'a option;
    mutable obs_delivered_initialized : bool;
    mutable obs_delivery_pending : bool;
    mutable obs_failed_without_current : bool;
    mutable obs_state : observer_state;
    mutable obs_staged_generation : int;
    mutable obs_on_dispose : (unit -> unit) list;
  }

  and packed_observer = O : 'a observer -> packed_observer

  and timer_node = {
    mutable timer_active : bool;
    mutable timer_running_generation : int option;
    mutable timer_cancel : (unit -> unit) option;
    mutable timer_finished : bool;
    mutable timer_generation : int;
    timer_start : 'err. timer_node -> (unit, 'err) Effect.t;
  }

  and timer_update = {
    timer_update : 'err. timer_node -> int -> (unit, 'err) Effect.t;
  }

  and 'a source_timer_update = {
    source_timer_update : 'err. timer_node -> int -> 'a var -> (unit, 'err) Effect.t;
  }

  type event = E : 'a observer * 'a update -> event

  type lane_waiter_state =
    | Lane_waiting
    | Lane_granted
    | Lane_claimed
    | Lane_cancelled

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
    mutable observers : packed_observer list;
    mutable all_nodes : packed_signal list;
    mutable current_scope : scope option;
    mutable pure_snapshot_commit_count : int;
    mutable callback_delivery_count : int;
    mutable recompute_count : int;
    mutable dynamic_scope_invalidations : int;
    mutable nodes_became_necessary : int;
    mutable nodes_became_unnecessary : int;
    mutable necessary_node_ids : (signal_id, unit) Hashtbl.t;
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
      observers = [];
      all_nodes = [];
      current_scope = None;
      pure_snapshot_commit_count = 0;
      callback_delivery_count = 0;
      recompute_count = 0;
      dynamic_scope_invalidations = 0;
      nodes_became_necessary = 0;
      nodes_became_unnecessary = 0;
      necessary_node_ids = Hashtbl.create 16;
    }

  let graph_context_error_message =
    "Eta_signal: signal graph APIs must be called on the domain that created "
    ^ "the graph and not from runtime worker callbacks"

  let ensure_graph_context () =
    if
      Domain.self () <> graph.owner_domain
      || Runtime_contract.in_registered_worker_context ()
    then invalid_arg graph_context_error_message

  let with_lane_lock lane f = Sync_lock.use lane.lane_lock f

  let rec take_waiting_waiter waiters =
    if Stdlib.Queue.is_empty waiters then None
    else
      let waiter = Stdlib.Queue.take waiters in
      match waiter.lane_state with
      | Lane_waiting -> Some waiter
      | Lane_granted | Lane_claimed | Lane_cancelled ->
          take_waiting_waiter waiters

  let compact_cancelled_lane_waiters_locked lane =
    if lane.lane_cancelled > 0 then (
      let live = Stdlib.Queue.create () in
      Stdlib.Queue.iter
        (fun waiter ->
          match waiter.lane_state with
          | Lane_waiting -> Stdlib.Queue.push waiter live
          | Lane_granted | Lane_claimed | Lane_cancelled -> ())
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
        lane.lane_cancelled <- lane.lane_cancelled + 1;
        compact_cancelled_lane_waiters_locked lane;
        None
    | Lane_granted ->
        waiter.lane_state <- Lane_cancelled;
        lane.lane_cancelled <- lane.lane_cancelled + 1;
        release_lane_locked lane
    | Lane_claimed ->
        waiter.lane_state <- Lane_cancelled;
        lane.lane_cancelled <- lane.lane_cancelled + 1;
        release_lane_locked lane
    | Lane_cancelled -> None

  let claim_lane_waiter_locked waiter =
    match waiter.lane_state with
    | Lane_granted -> waiter.lane_state <- Lane_claimed
    | Lane_waiting ->
        invalid_arg "Eta_signal lane waiter was not granted"
    | Lane_claimed | Lane_cancelled -> ()

  let with_lane_lock_during_cancel contract lane f =
    contract.Runtime_contract.protect (fun () -> with_lane_lock lane f)

  let enqueue_lane_waiter contract lane =
    let promise, resolver = contract.Runtime_contract.create_promise () in
    let waiter =
      { lane_contract = contract; lane_resolver = resolver; lane_state = Lane_waiting }
    in
    Stdlib.Queue.push waiter lane.lane_waiters;
    lane.lane_waiting <- lane.lane_waiting + 1;
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
        try
          contract.Runtime_contract.await_promise promise;
          with_lane_lock_during_cancel contract lane (fun () ->
              claim_lane_waiter_locked waiter)
        with exn
          when Option.is_some (contract.Runtime_contract.cancellation_reason exn) ->
          with_lane_lock_during_cancel contract lane (fun () ->
              cancel_lane_waiter_locked lane waiter)
          |> Option.iter resolve_lane_waiter;
          raise exn)

  let leave_lane_sync lane =
    with_lane_lock lane (fun () -> release_lane_locked lane)
    |> Option.iter resolve_lane_waiter

  let release_graph_lane_sync owns_lane =
    if !owns_lane then (
      owns_lane := false;
      leave_lane_sync graph.lane)

  let release_graph_lane owns_lane =
    Effect.sync (fun () -> release_graph_lane_sync owns_lane)

  let with_graph_lane eff =
    Effect.Expert.make ~leaf_name:"Eta_signal.with_graph_lane" (fun context ->
        let contract = Effect.Expert.contract context in
        let owns_lane = ref false in
        let release_after_interrupt () =
          contract.Runtime_contract.protect (fun () ->
              release_graph_lane_sync owns_lane)
        in
        try
          ensure_graph_context ();
          enter_lane_sync contract graph.lane;
          owns_lane := true;
          Effect.Expert.eval context
            (eff |> Effect.on_exit (fun _exit -> release_graph_lane owns_lane))
        with
        | exn
          when Option.is_some
                 (contract.Runtime_contract.cancellation_reason exn) ->
            release_after_interrupt ();
            raise exn
        | exn ->
            release_after_interrupt ();
            Effect.Expert.exit_of_exn context exn)

  let with_graph_lane_sync f = with_graph_lane (Effect.sync f)

  let next_id () =
    ensure_graph_context ();
    let id = graph.next_id in
    graph.next_id <- id + 1;
    id

  let next_signal_id () = Signal_id (next_id ())
  let next_var_id () = Var_id (next_id ())
  let next_observer_id () = Observer_id (next_id ())

  let new_scope () =
    let id = graph.next_scope_id in
    graph.next_scope_id <- id + 1;
    { scope_id = Scope_id id; scope_valid = true; scope_nodes = [] }

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
      | Some _ -> saturating_succ signal.version
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

  let stage_observer_delivered_current observer value =
    remember_staged_observer (O observer);
    observer.obs_staged_delivered_current <- Some value

  let observer_active (O observer) =
    match observer.obs_state with
    | Observer_active -> true
    | Observer_disposed | Observer_invalid_scope -> false

  let remove_observer observer =
    graph.observers <-
      List.filter
        (fun (O candidate) -> candidate.obs_id <> observer.obs_id)
        graph.observers

  let finish_observer_unlocked observer state =
    match observer.obs_state with
    | Observer_active ->
        observer.obs_state <- state;
        remove_observer observer;
        List.iter (fun f -> f ()) observer.obs_on_dispose;
        observer.obs_on_dispose <- []
    | Observer_disposed | Observer_invalid_scope -> ()

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
    List.iter (fun (O observer) -> invalidate_observer_unlocked observer) observers

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

  let validate_bind_inner_scope scope inner =
    if not inner.valid then raise (Graph_error `Invalid_scope);
    match inner.scope with
    | None -> ()
    | Some inner_scope when inner_scope == scope -> ()
    | Some _ -> raise (Graph_error `Invalid_scope)

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

  let rec invalidate_scope ?(prune = true) scope =
    if scope.scope_valid then (
      scope.scope_valid <- false;
      graph.dynamic_scope_invalidations <-
        saturating_succ graph.dynamic_scope_invalidations;
      List.iter invalidate_node scope.scope_nodes;
      scope.scope_nodes <- [];
      if prune then prune_invalid_nodes_unlocked ())

  and invalidate_node (P signal) =
    if signal.valid then (
      let dependencies = signal.dependencies in
      let dependents = signal.dependents in
      Option.iter
        (fun timer ->
          timer.timer_active <- false;
          timer.timer_generation <- timer.timer_generation + 1)
        signal.timer;
      signal.valid <- false;
      dispose_signal_observers signal;
      List.iter
        (fun (P dependency) -> remove_dependent dependency signal)
        dependencies;
      signal.dependencies <- [];
      signal.dependents <- [];
      List.iter invalidate_node dependents;
      match signal.kind with
      | Var source -> remove_var_watcher source signal
      | Bind bind -> (
          match bind.inner_scope with
          | None -> ()
          | Some scope -> invalidate_scope ~prune:false scope)
      | Const _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _ | Map6 _ | Map7 _
      | Map8 _ | Map9 _ | All _ ->
          ())

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

  let commit_signal (P signal) =
    if signal.staged_generation = current_generation () then (
      (match signal.staged with
       | None -> ()
       | Some value ->
           signal.value <- Some value;
           signal.initialized <- true;
           signal.version <- saturating_succ signal.version);
      signal.staged <- None;
      (match signal.staged_dependency_versions with
       | None -> ()
       | Some dependency_versions ->
           signal.dependency_versions <- dependency_versions);
      signal.staged_dependency_versions <- None);
    signal.dirty <- false

  let rollback_signal (P signal) =
    if signal.staged_generation = current_generation () then (
      signal.staged <- None;
      signal.staged_dependency_versions <- None)

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
      (match
         ( bind.owner,
           bind.staged_source_value,
           bind.staged_inner,
           bind.staged_inner_scope )
       with
       | Some owner, Some source_value, Some inner, Some scope ->
           (match bind.inner with
            | None -> ()
            | Some old_inner -> detach_dependency owner old_inner);
           (match bind.inner_scope with
            | None -> ()
            | Some old_scope -> invalidate_scope old_scope);
           bind.source_value <- Some source_value;
           bind.inner <- Some inner;
           bind.inner_scope <- Some scope;
           attach_dependency owner inner
       | _ -> raise (Graph_error `Invalid_scope));
      clear_staged_bind bind)

  let rollback_bind (B bind) =
    if bind.staged_bind_generation = current_generation () then (
      Option.iter invalidate_scope bind.staged_inner_scope;
      clear_staged_bind bind)

  let commit_observer (O observer) =
    if observer.obs_staged_generation = current_generation () then (
      (match observer.obs_staged_current with
       | None -> ()
       | Some value ->
           observer.obs_current <- Some value;
           observer.obs_failed_without_current <- false;
           observer.obs_initialized <- true);
      (match observer.obs_staged_delivered_current with
       | None -> ()
       | Some value ->
           observer.obs_delivered_current <- Some value;
           observer.obs_delivered_initialized <- true;
           observer.obs_delivery_pending <- false);
      observer.obs_staged_current <- None;
      observer.obs_staged_delivered_current <- None)

  let rollback_observer (O observer) =
    if observer.obs_staged_generation = current_generation () then (
      observer.obs_staged_current <- None;
      observer.obs_staged_delivered_current <- None)

  let reset_staging () =
    List.iter rollback_signal graph.computed_nodes;
    List.iter rollback_var graph.staged_vars;
    List.iter rollback_bind graph.staged_binds;
    List.iter rollback_observer graph.staged_observers;
    graph.computed_nodes <- [];
    graph.staged_vars <- [];
    graph.staged_binds <- [];
    graph.staged_observers <- []

  let commit_staging () =
    List.iter commit_var graph.staged_vars;
    List.iter commit_bind graph.staged_binds;
    List.iter commit_signal graph.computed_nodes;
    List.iter commit_observer graph.staged_observers;
    graph.computed_nodes <- [];
    graph.staged_vars <- [];
    graph.staged_binds <- [];
    graph.staged_observers <- [];
    graph.pure_snapshot_commit_count <-
      saturating_succ graph.pure_snapshot_commit_count

  let requeue_if_needed (V var as packed) =
    if not var.queued then (
      var.queued <- true;
      graph.pending_vars <- packed :: graph.pending_vars)

  let mark_failed_without_current (O observer) =
    if observer.obs_current = None then observer.obs_failed_without_current <- true

  let rollback_pure observers pending_at_start =
    reset_staging ();
    List.iter mark_failed_without_current observers;
    List.iter requeue_if_needed pending_at_start;
    graph.phase <- Not_stabilizing

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
          let scope = new_scope () in
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
              graph.current_scope <- previous_scope;
              invalidate_scope scope;
              raise exn
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

  let timer_stop_unlocked ?(cancel_running = true) timer =
    let cancel = timer.timer_cancel in
    timer.timer_active <- false;
    timer.timer_generation <- timer.timer_generation + 1;
    timer.timer_running_generation <- None;
    timer.timer_cancel <- None;
    if cancel_running then Option.iter (fun cancel -> cancel ()) cancel

  let timer_finish_unlocked timer =
    timer.timer_finished <- true;
    timer_stop_unlocked ~cancel_running:false timer

  let timer_has_current_daemon timer =
    match timer.timer_running_generation with
    | Some generation -> generation = timer.timer_generation
    | None -> false

  let timer_start_unlocked timer =
    if timer.timer_finished || (timer.timer_active && timer_has_current_daemon timer)
    then None
    else (
      timer.timer_active <- true;
      timer.timer_generation <- timer.timer_generation + 1;
      timer.timer_running_generation <- Some timer.timer_generation;
      timer.timer_cancel <- None;
      Some (timer.timer_start timer))

  let collect_necessary_node_ids () =
    let seen = Hashtbl.create 16 in
    let rec visit (P signal) =
      if signal.valid && not (Hashtbl.mem seen signal.id) then (
        Hashtbl.add seen signal.id ();
        List.iter visit signal.dependencies)
    in
    List.iter
      (fun (O observer) ->
        if observer_active (O observer) then visit (P observer.obs_signal))
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
        if observer_active (O observer) then visit (P observer.obs_signal))
      graph.observers;
    timers

  let all_timers () =
    List.filter_map
      (fun (P signal) -> Option.map (fun timer -> (signal.id, timer)) signal.timer)
      graph.all_nodes

  let refresh_timer_demand_unlocked () =
    let needed = necessary_timers () in
    all_timers ()
    |> List.filter_map (fun (id, timer) ->
           if Hashtbl.mem needed id then timer_start_unlocked timer
           else (
             timer_stop_unlocked timer;
             None))

  let refresh_timer_demand () =
    with_graph_lane_sync refresh_timer_demand_unlocked
    |> Effect.bind Effect.concat

  let dispose_observer_effect observer =
    with_graph_lane_sync
      (fun () ->
        if observer_active (O observer) then (
          dispose_observer_unlocked observer;
          update_necessity_counters_unlocked ()))
    |> Effect.bind (fun () -> refresh_timer_demand ())

  let collect_observer_event (O observer) =
    if not (observer_active (O observer)) then None
    else (
      let value, changed = compute observer.obs_signal in
      let event =
        if not observer.obs_delivered_initialized then Some (Initialized value)
        else
          match observer.obs_delivered_current with
          | None -> Some (Initialized value)
          | Some old_value ->
              if changed || observer.obs_delivery_pending then
                if observer.obs_equal old_value value then (
                  stage_observer_delivered_current observer value;
                  None)
                else Some (Changed { old_value; new_value = value })
              else None
      in
      stage_observer_current observer value;
      Option.map (fun update -> E (observer, update)) event)

  let mark_event_pending (E (observer, _)) =
    observer.obs_delivery_pending <- true

  let delivered_value = function
    | Initialized value -> value
    | Changed { new_value; _ } -> new_value

  let acknowledge_event_delivery observer update =
    observer.obs_delivered_current <- Some (delivered_value update);
    observer.obs_delivered_initialized <- true;
    observer.obs_delivery_pending <- false

  let begin_stabilize () =
    if graph.phase <> Not_stabilizing then Error `Reentrant_stabilization
    else (
      graph.phase <- Pure;
      graph.stabilization_id <- graph.stabilization_id + 1;
      graph.computed_nodes <- [];
      graph.staged_vars <- [];
      graph.staged_binds <- [];
      graph.staged_observers <- [];
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
        commit_staging ();
        List.iter mark_event_pending events;
        update_necessity_counters_unlocked ();
        graph.phase <- Running_observers;
        Ok events
      with
      | Graph_error err ->
          rollback_pure observers pending_at_start;
          Error err
      | exn ->
          rollback_pure observers pending_at_start;
          raise exn)

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

  let run_observer_effect observer update observer_eff =
    Effect.Expert.make ~leaf_name:"eta_signal.observer" @@ fun context ->
    let exit =
      try
        match Effect.Expert.eval context observer_eff with
        | Eta.Exit.Ok () -> Eta.Exit.Ok ()
        | Eta.Exit.Error cause ->
            Eta.Exit.Error (observer_cause_to_stabilize cause)
      with
      | Graph_error err ->
          Eta.Exit.Error (Eta.Cause.Fail (err :> stabilize_error))
    in
    match exit with
    | Eta.Exit.Ok () ->
        acknowledge_event_delivery observer update;
        Eta.Exit.Ok ()
    | Eta.Exit.Error _ as error -> error

  let mark_callback_delivery_complete () =
    with_graph_lane_sync (fun () ->
        graph.callback_delivery_count <-
          saturating_succ graph.callback_delivery_count)

  let event_observer_active observer =
    with_graph_lane_sync (fun () -> observer_active (O observer))

  let rec run_events = function
    | [] -> Effect.unit
    | E (observer, update) :: rest -> (
        event_observer_active observer
        |> Effect.bind (function
             | false -> run_events rest
             | true -> (
                 match
                   try Ok (observer.obs_callback update)
                   with Graph_error err -> Error (err :> stabilize_error)
                 with
                 | Error err -> Effect.fail err
                 | Ok observer_eff ->
                     run_observer_effect observer update observer_eff
                     |> Effect.bind (fun () -> run_events rest))))

  let stabilize =
    with_graph_lane_sync begin_stabilize
    |> Effect.map (function
         | Ok events -> Ok events
         | Error (#graph_error as err) -> Error (err :> stabilize_error))
    |> Effect.flatten_result
    |> Effect.bind (fun events ->
           (refresh_timer_demand ()
            |> Effect.bind (fun () -> run_events events)
            |> Effect.bind mark_callback_delivery_complete)
           |> Effect.on_exit (fun _exit -> with_graph_lane_sync finish_stabilize))

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

    let set (source : 'a t) value =
      with_graph_lane_sync @@ fun () ->
      source.source_value <- value;
      queue_var source

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
                     set source new_value |> Effect.map (fun () -> new_value))))
      |> Effect.on_exit (fun _ -> release_if_acquired ())
  end

  module Observer = struct
    type 'a t = 'a observer

    let observe_with_hooks ?(equal = default_equal) ?(on_dispose = []) signal
        callback =
      with_graph_lane_sync (fun () ->
          if not signal.valid then Error `Invalid_scope
          else
            let observer =
              {
                obs_id = next_observer_id ();
                obs_signal = signal;
                obs_equal = equal;
                obs_callback = callback;
                obs_current = None;
                obs_staged_current = None;
                obs_initialized = false;
                obs_delivered_current = None;
                obs_staged_delivered_current = None;
                obs_delivered_initialized = false;
                obs_delivery_pending = false;
                obs_failed_without_current = false;
                obs_state = Observer_active;
                obs_staged_generation = -1;
                obs_on_dispose = on_dispose;
              }
            in
            graph.observers <- O observer :: graph.observers;
            update_necessity_counters_unlocked ();
            Ok observer)
      |> Effect.flatten_result
      |> Effect.bind (fun observer ->
             let transferred = ref false in
             (refresh_timer_demand ()
             |> Effect.map (fun () ->
                    transferred := true;
                    observer))
             |> Effect.on_exit (fun _exit ->
                    if !transferred then Effect.unit
                    else dispose_observer_effect observer))

    let observe ?equal signal callback = observe_with_hooks ?equal signal callback

    let read observer =
      Effect.sync (fun () ->
          ensure_graph_context ();
          match observer.obs_state with
          | Observer_disposed -> Error `Disposed_observer
          | Observer_invalid_scope -> Error `Invalid_scope
          | Observer_active -> (
              match observer.obs_current with
              | Some value -> Ok value
              | None ->
                  if
                    observer.obs_failed_without_current
                    || observer.obs_initialized
                  then Error `No_current_value
                  else Error `Uninitialized_observer))
      |> Effect.flatten_result

    let unsafe_read_exn observer =
      ensure_graph_context ();
      match observer.obs_state with
      | Observer_disposed -> invalid_arg "Eta_signal observer is disposed"
      | Observer_invalid_scope ->
          invalid_arg "Eta_signal observer scope is invalid"
      | Observer_active -> (
          match observer.obs_current with
          | Some value -> value
          | None -> invalid_arg "Eta_signal observer is not initialized")

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
      (fun count (O observer as packed) ->
        if observer_active packed && not observer.obs_signal.valid then
          saturating_succ count
        else count)
      0 graph.observers

  let necessary_node_count () =
    Hashtbl.length (collect_necessary_node_ids ())

  let dead_node_count () =
    List.fold_left
      (fun count (P signal) ->
        if signal.valid then count else saturating_succ count)
      0 graph.all_nodes

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
    | None -> [ "scope=root"; "scope_id=root" ]
    | Some scope ->
        [
          "scope="
          ^ scope_id_label scope.scope_id
          ^ ":"
          ^ (if scope.scope_valid then "valid" else "invalid");
          "scope_id=" ^ scope_id_label scope.scope_id;
        ]

  let signal_timer_fields : type a. a signal -> string list =
   fun signal ->
    match signal.timer with
    | None -> []
    | Some timer ->
        let running =
          match timer.timer_running_generation with
          | None -> "none"
          | Some generation -> string_of_int generation
        in
        [
          bool_field "timer_active" timer.timer_active;
          "timer_running=" ^ running;
          bool_field "timer_cancel" (Option.is_some timer.timer_cancel);
          bool_field "timer_finished" timer.timer_finished;
          "timer_generation=" ^ string_of_int timer.timer_generation;
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

  let observer_state_label = function
    | Observer_active -> "active"
    | Observer_disposed -> "disposed"
    | Observer_invalid_scope -> "invalid_scope"

  let observer_label (O observer) =
    String.concat " "
      [
        "observer:" ^ observer_id_label observer.obs_id;
        "observer_id=" ^ observer_id_label observer.obs_id;
        "state=" ^ observer_state_label observer.obs_state;
        bool_field "initialized" observer.obs_initialized;
        bool_field "delivered" observer.obs_delivered_initialized;
        bool_field "pending" observer.obs_delivery_pending;
        bool_field "failed_without_current" observer.obs_failed_without_current;
      ]

  let to_dot ?(options = default_dot_options) () =
    with_graph_lane_sync @@ fun () ->
    let necessary = collect_necessary_node_ids () in
    let selected signal = signal_selected options necessary signal in
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
    if options.dot_observers then
      List.iter
        (fun (O observer as packed) ->
          if observer_active packed then (
            Format.fprintf formatter "  %s [shape=box,label=%S];@."
              (observer_id_label observer.obs_id)
              (observer_label packed);
            if selected observer.obs_signal then
              Format.fprintf formatter
                "  %s -> %s [style=dashed,label=\"observes\"];@."
                (signal_id_label observer.obs_signal.id)
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

    let install_timer_cancel timer generation cancel =
      with_graph_lane_sync (fun () ->
          if
            timer.timer_active
            && timer.timer_running_generation = Some generation
          then (
            timer.timer_cancel <- Some cancel;
            `Continue)
          else `Stop)

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
          if timer.timer_running_generation = Some generation then (
            timer.timer_running_generation <- None;
            timer.timer_cancel <- None))

    let timer_mark_failed timer generation =
      with_graph_lane_sync (fun () ->
          if timer.timer_running_generation = Some generation then (
            timer.timer_running_generation <- None;
            timer.timer_cancel <- None;
            if timer.timer_active then
              timer_stop_unlocked ~cancel_running:false timer))

    let timer_cleanup_after_exit timer generation = function
      | Eta.Exit.Ok _ -> timer_mark_stopped timer generation
      | Eta.Exit.Error _ -> timer_mark_failed timer generation

    let timer_cleanup_failed_start timer generation = function
      | Eta.Exit.Ok _ -> Effect.unit
      | Eta.Exit.Error _ -> timer_mark_failed timer generation

    let timer_after_update_state timer generation =
      with_graph_lane_sync (fun () ->
          if
            timer.timer_active
            && timer.timer_generation = generation
            && timer.timer_running_generation = Some generation
          then `Continue
          else (
            if timer.timer_running_generation = Some generation then (
              timer.timer_running_generation <- None;
              timer.timer_cancel <- None);
            `Stop))

    let timer_set_source timer generation (source : 'a var) value =
      with_graph_lane_sync (fun () ->
          if
            timer.timer_active
            && timer.timer_generation = generation
            && timer.timer_running_generation = Some generation
          then (
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
      else saturating_succ ((now_ms - next_due_ms) / interval_ms)

    let advance_due next_due_ms interval_ms missed =
      add_ms_capped next_due_ms (mul_ms_capped interval_ms missed)

    let rec run_timer_updates timer generation remaining update =
      if remaining <= 0 then Effect.unit
      else
        timer_after_update_state timer generation
        |> Effect.bind (function
             | `Stop -> Effect.unit
             | `Continue ->
                 Effect.sync (fun () -> update.timer_update timer generation)
                 |> Effect.bind (fun update_eff -> update_eff)
                 |> Effect.bind (fun () ->
                        run_timer_updates timer generation (remaining - 1) update))

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

    let attach_timer ?(update_on_start = false) signal interval update =
      let timer =
        {
          timer_active = false;
          timer_running_generation = None;
          timer_cancel = None;
          timer_finished = false;
          timer_generation = 0;
          timer_start =
            (fun timer ->
              let generation = timer.timer_generation in
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
              if update_on_start then
                (update.timer_update timer generation
                |> Effect.bind (fun () ->
                       timer_after_update_state timer generation
                       |> Effect.bind (function
                            | `Continue -> start_loop ()
                            | `Stop -> Effect.unit)))
                |> Effect.on_exit (timer_cleanup_failed_start timer generation)
              else start_loop ());
        }
      in
      signal.timer <- Some timer;
      signal

    let make_timer_signal ?(update_on_start = false) ?equal initial interval
        update =
      let source = Var.create ?equal initial in
      let signal = Var.watch source in
      attach_timer ~update_on_start signal interval
        {
          timer_update =
            (fun timer generation ->
              update.source_timer_update timer generation source);
        }

    let now ~every () =
      Effect.sync (fun () -> validate_interval every)
      |> Effect.flatten_result
      |> Effect.bind (fun () ->
             Effect.now
             |> Effect.map (fun initial ->
                    make_timer_signal ~update_on_start:true ~equal:Int.equal
                      initial every
                      {
                        source_timer_update =
                          (fun timer generation source ->
                            Effect.now
                            |> Effect.bind (fun now_ms ->
                                   timer_set_source timer generation source now_ms
                                   |> Effect.map (fun _ -> ())));
                      }))

    let deadline ~every deadline_ms =
      Effect.sync (fun () -> validate_interval every)
      |> Effect.flatten_result
      |> Effect.bind (fun () ->
             Effect.now
             |> Effect.bind (fun now_ms ->
                    Effect.from_result (validate_future now_ms deadline_ms)
                    |> Effect.map (fun () ->
                           make_timer_signal ~update_on_start:true
                             ~equal:Bool.equal false every
                             {
                               source_timer_update =
                                 (fun timer generation source ->
                                   Effect.now
                                   |> Effect.bind (fun now_ms ->
                                          if now_ms >= deadline_ms then
                                            timer_set_source timer generation
                                              source true
                                            |> Effect.bind (function
                                                 | `Updated ->
                                                     with_graph_lane_sync
                                                       (fun () ->
                                                         timer_finish_unlocked
                                                           timer)
                                                 | `Stopped -> Effect.unit)
                                          else
                                            timer_set_source timer generation
                                              source false
                                            |> Effect.map (fun _ -> ())));
                             })))

    let after ~every duration =
      Effect.sync (fun () -> validate_interval duration)
      |> Effect.flatten_result
      |> Effect.bind (fun () ->
             Effect.now
             |> Effect.bind (fun now_ms ->
                    let deadline_ms =
                      add_ms_capped now_ms (Duration.to_ms duration)
                    in
                    deadline ~every deadline_ms))

    let interval interval =
      Effect.sync (fun () -> validate_interval interval)
      |> Effect.flatten_result
      |> Effect.map (fun () ->
             make_timer_signal ~equal:Int.equal 0 interval
               {
                 source_timer_update =
                   (fun timer generation source ->
                     let next = saturating_succ (Var.value source) in
                     timer_set_source timer generation source next
                     |> Effect.map (fun _ -> ()));
               })

    let step ~every ~initial f =
      Effect.sync (fun () -> validate_interval every)
      |> Effect.flatten_result
      |> Effect.map (fun () ->
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
               })
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

    let offer_bridge_update queue update =
      Queue.try_send queue update
      |> Effect.bind (function
           | `Sent | `Dropped | `Closed -> Effect.unit
           | `Full ->
               Effect.sync (fun () ->
                   failwith "Eta_signal.Stream.observe: unexpected full queue")
           | `Closed_with_error _ ->
               Effect.sync (fun () ->
                   failwith
                     "Eta_signal.Stream.observe: bridge queue closed with error"))

    let observe ?(capacity = default_capacity) ?equal signal =
      Effect.sync (fun () -> create_bridge_queue capacity)
      |> Effect.flatten_result
      |> Effect.bind (fun queue ->
             Observer.observe_with_hooks ?equal
               ~on_dispose:[ (fun () -> Queue.close queue) ]
               signal
               (offer_bridge_update queue)
             |> Effect.map_error (fun err -> (err :> stream_error))
             |> Effect.map (fun observer ->
                    (observer, Eta_stream.Stream.from_queue queue)))
  end
end
