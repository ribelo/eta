module E = Eta.Effect
module Core = Selected_core
module Cutoff = Eta_signal_cutoff
module Lane = Eta_signal_lane

module type Observer_error = sig
  type t
  val pp : Format.formatter -> t -> unit
end

module No_observer_error = struct
  type t = |
  let pp _ (error : t) = match error with _ -> .
end

type graph_error =
  [ `Ambiguous_scope
  | `Counter_overflow of string
  | `Cycle
  | `Invalid_scope
  | `Reentrant_stabilization
  | `Runtime_mismatch
  | `Reentrant_update ]

module type Package_graph = sig
  type 'a signal
  type 'a plan
  type 'a change = Left of 'a | Right of 'a | Changed of 'a * 'a
  type ('key, 'data, 'map) input_ops = {
    empty : 'map;
    compare_key : 'key -> 'key -> int;
    fold_symmetric_diff :
      'acc. 'map -> 'map -> on_compare:(unit -> unit) -> init:'acc ->
      f:('acc -> 'key -> 'data change -> 'acc) -> 'acc;
  }
  type ('key, 'output, 'map) output_ops = {
    empty : 'map;
    set : 'key -> 'output -> 'map -> 'map;
    remove : 'key -> 'map -> 'map;
  }
  val stable_family :
    ?data_cutoff:'data Cutoff.t ->
    input:'data_map signal ->
    input_ops:('key, 'data, 'data_map) input_ops ->
    output_ops:('key, 'output, 'output_map) output_ops ->
    build:(key:'key -> data:'data signal -> 'output signal) ->
    unit -> 'output_map plan
  val install : 'a plan -> 'a signal
end

module type Stream_source = sig
  type 'a signal
  type 'a observer
  type 'a update
  type 'a delivery
  type observer_error
  type observer_finish = [ `Disposed | `Invalid_scope ]
  val observe_delivery :
    ?cutoff:'a Cutoff.t -> ?on_finish:(observer_finish -> unit) ->
    'a signal -> ('a delivery -> (unit, observer_error) E.t) ->
    ('a observer, graph_error) E.t
  val current : 'a delivery -> ('a update option, 'error) E.t
  val acknowledge : 'a delivery -> (unit, 'error) E.t
  val dispose : 'a observer -> (unit, graph_error) E.t
end

module type Result = sig
  type observer_error
  type nonrec graph_error = graph_error
  exception Graph_error of graph_error
  type observer_read_error =
    [ `Disposed_observer | `Invalid_scope | `No_current_value
    | `Uninitialized_observer ]
  type stabilize_error = [ graph_error | `Observer_error of observer_error ]
  type time_error =
    [ graph_error | `Deadline_overflow | `Invalid_interval | `Past_deadline ]
  type 'a var
  type 'a signal
  type 'a observer
  type 'a update =
    | Initialized of 'a
    | Changed of { old_value : 'a; new_value : 'a }
  type keyed_stats = {
    node_count : int;
    committed_child_count : int;
    reconciliation_count : int;
    input_key_comparison_count : int;
    input_diff_event_count : int;
    child_visit_count : int;
    provisional_addition_count : int;
    committed_addition_count : int;
    committed_removal_count : int;
    reconciliation_rollback_count : int;
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
    lane_waiter_count : int;
    lane_cancelled_waiter_count : int;
    keyed : keyed_stats;
  }
  type dot_scope = [ `Necessary | `All_valid | `All_including_invalid ]
  type dot_options = {
    dot_scope : dot_scope;
    dot_observers : bool;
    dot_timers : bool;
    dot_state : bool;
    dot_dynamic_scopes : bool;
  }
  val default_dot_options : dot_options
  val pp_graph_error : Format.formatter -> graph_error -> unit
  val pp_observer_read_error : Format.formatter -> observer_read_error -> unit
  val pp_stabilize_error : Format.formatter -> stabilize_error -> unit
  val pp_time_error : Format.formatter -> time_error -> unit
  module Var : sig
    type 'a t = 'a var
    val create : ?cutoff:'a Cutoff.t -> 'a -> 'a t
    val value : 'a t -> 'a
    val watch : 'a t -> 'a signal
    val set : 'a t -> 'a -> (unit, [> `Reentrant_update ] as 'err) E.t
    val update_effect :
      'a t -> ('a -> ('a, 'err) E.t) ->
      ('a, [> `Reentrant_update ] as 'err) E.t
  end
  module Observer : sig
    type 'a t = 'a observer
    type observer_finish = [ `Disposed | `Invalid_scope ]
    val observe :
      ?cutoff:'a Cutoff.t -> ?on_finish:(observer_finish -> unit) ->
      ?on_update:('a update -> (unit, observer_error) E.t) ->
      'a signal -> ('a t, graph_error) E.t
    val read : 'a t -> ('a, observer_read_error) E.t
    val dispose : 'a t -> (unit, graph_error) E.t
  end
  module For_stream :
    Stream_source
      with type 'a signal = 'a signal
       and type 'a observer = 'a observer
       and type 'a update = 'a update
       and type observer_error = observer_error
  module Package : Package_graph with type 'a signal = 'a signal
  val const : 'a -> 'a signal
  val map : ?cutoff:'b Cutoff.t -> ('a -> 'b) -> 'a signal -> 'b signal
  val map2 :
    ?cutoff:'c Cutoff.t -> ('a -> 'b -> 'c) ->
    'a signal -> 'b signal -> 'c signal
  val map3 :
    ?cutoff:'d Cutoff.t -> ('a -> 'b -> 'c -> 'd) ->
    'a signal -> 'b signal -> 'c signal -> 'd signal
  val map4 :
    ?cutoff:'e Cutoff.t -> ('a -> 'b -> 'c -> 'd -> 'e) ->
    'a signal -> 'b signal -> 'c signal -> 'd signal -> 'e signal
  val map5 :
    ?cutoff:'f Cutoff.t -> ('a -> 'b -> 'c -> 'd -> 'e -> 'f) ->
    'a signal -> 'b signal -> 'c signal -> 'd signal -> 'e signal -> 'f signal
  val map6 :
    ?cutoff:'g Cutoff.t -> ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g) ->
    'a signal -> 'b signal -> 'c signal -> 'd signal -> 'e signal ->
    'f signal -> 'g signal
  val map7 :
    ?cutoff:'h Cutoff.t ->
    ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g -> 'h) ->
    'a signal -> 'b signal -> 'c signal -> 'd signal -> 'e signal ->
    'f signal -> 'g signal -> 'h signal
  val map8 :
    ?cutoff:'i Cutoff.t ->
    ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g -> 'h -> 'i) ->
    'a signal -> 'b signal -> 'c signal -> 'd signal -> 'e signal ->
    'f signal -> 'g signal -> 'h signal -> 'i signal
  val map9 :
    ?cutoff:'j Cutoff.t ->
    ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g -> 'h -> 'i -> 'j) ->
    'a signal -> 'b signal -> 'c signal -> 'd signal -> 'e signal ->
    'f signal -> 'g signal -> 'h signal -> 'i signal -> 'j signal
  val reduce_balanced :
    ?cutoff:'a Cutoff.t -> identity:'a -> combine:('a -> 'a -> 'a) ->
    'a signal array -> 'a signal
  val all : ?cutoff:'a list Cutoff.t -> 'a signal list -> 'a list signal
  val bind :
    ?cutoff:'b Cutoff.t -> f:('a -> 'b signal) -> 'a signal -> 'b signal
  val stabilize : (unit, stabilize_error) E.t
  val stats : unit -> (stats, graph_error) E.t
  val to_dot : ?options:dot_options -> unit -> (string, 'err) E.t
  module Time : sig
    type monotonic_time
    val to_ms : monotonic_time -> int
    val add :
      monotonic_time -> Eta.Duration.t ->
      (monotonic_time, [> `Deadline_overflow | `Past_deadline ]) result
    val now : every:Eta.Duration.t -> (monotonic_time signal, time_error) E.t
    val deadline : monotonic_time -> (bool signal, time_error) E.t
    val after : Eta.Duration.t -> (bool signal, time_error) E.t
    val interval : Eta.Duration.t -> (int signal, time_error) E.t
  end
end

let pp_graph_error ppf = function
  | `Ambiguous_scope -> Format.pp_print_string ppf "ambiguous dynamic scope"
  | `Counter_overflow name ->
      Format.fprintf ppf "counter overflow: %s" name
  | `Cycle -> Format.pp_print_string ppf "cycle detected"
  | `Invalid_scope -> Format.pp_print_string ppf "invalid dynamic scope"
  | `Reentrant_stabilization ->
      Format.pp_print_string ppf "reentrant stabilization"
  | `Runtime_mismatch ->
      Format.pp_print_string ppf "timer used from a different Eta runtime"
  | `Reentrant_update ->
      Format.pp_print_string ppf "same-variable effectful update reentry"

module Execution = struct
  type t = {
    lane : Lane.t;
    owner_domain : Domain.id;
    depth_local : int Eta.Runtime_contract.local;
    mutable owner_fiber_id : int option;
  }

  let hooks =
    Lane.hooks ~note_waiter_enqueued:(fun () -> ())
      ~note_waiter_compaction:(fun () -> ())

  let create () =
    {
      lane = Lane.create ();
      owner_domain = Domain.self ();
      depth_local =
        Eta.Runtime_contract.create_local
          ~inheritance:Eta.Runtime_contract.Fiber_local ();
      owner_fiber_id = None;
    }

  let ensure_context t =
    if Domain.self () <> t.owner_domain
       || Eta.Runtime_contract.in_registered_worker_context ()
    then
      invalid_arg
        "Eta_signal: signal graph APIs must be called on the domain that created \
         the graph and not from runtime worker callbacks"

  let run t operation =
    Eta.Spi.Expert.make ~leaf_name:"eta_signal.execution" @@ fun context ->
    let contract = Eta.Spi.Expert.contract context in
    let finish = function
      | Ok value -> Eta.Exit.Ok value
      | Error error -> Eta.Exit.Error (Eta.Cause.Fail error)
    in
    let body () = finish (operation contract.Eta.Runtime_contract.check) in
    try
      ensure_context t;
      let fiber = contract.Eta.Runtime_contract.current_fiber_id () in
      match t.owner_fiber_id with
      | Some owner when owner = fiber -> body ()
      | _ ->
          let access = Lane.enter ~hooks contract t.lane in
          t.owner_fiber_id <- Some fiber;
          Fun.protect
            ~finally:(fun () ->
              contract.Eta.Runtime_contract.protect @@ fun () ->
              t.owner_fiber_id <- None;
              Lane.leave t.lane access)
            (fun () ->
              contract.Eta.Runtime_contract.local_with_binding
                t.depth_local 1 body)
    with
    | exn when Option.is_some (contract.Eta.Runtime_contract.cancellation_reason exn) ->
        raise exn
    | exn -> Eta.Spi.Expert.exit_of_exn context exn

  let sync t f =
    ensure_context t;
    f ()
end

module Edge_execution = struct
  type t = {
    execution : Execution.t;
    mutable contract : Eta.Runtime_contract.t option;
  }

  let create execution = { execution; contract = None }

  let run t operation =
    match t.execution.Execution.owner_fiber_id, t.contract with
    | Some _, _ -> operation (fun () -> ())
    | None, Some contract ->
        let fiber = contract.Eta.Runtime_contract.current_fiber_id () in
        let access =
          Lane.enter ~hooks:Execution.hooks contract t.execution.Execution.lane
        in
        t.execution.Execution.owner_fiber_id <- Some fiber;
        Fun.protect
          ~finally:(fun () ->
            contract.Eta.Runtime_contract.protect @@ fun () ->
            t.execution.Execution.owner_fiber_id <- None;
            Lane.leave t.execution.Execution.lane access)
          (fun () -> operation contract.Eta.Runtime_contract.check)
    | None, None ->
        invalid_arg "Eta_signal: edge operation has no active runtime"
end

module Edges = Selected_edges.Make (Edge_execution)

let current_runtime () =
  Eta.Spi.Expert.make ~leaf_name:"eta_signal.current_runtime"
    (fun context -> Eta.Exit.Ok (Eta.Spi.Expert.contract context))

module Make_impl (Observer_error : Observer_error) () = struct
  type observer_error = Observer_error.t
  type nonrec graph_error = graph_error
  exception Graph_error of graph_error
  exception Deferred_bind
  exception Deferred_source
  let pp_graph_error = pp_graph_error
  let runtime_mismatch_with_cleanup =
    Eta.Spi.Expert.make ~leaf_name:"eta_signal.runtime_mismatch_cleanup"
    @@ fun context ->
    Eta.Spi.Expert.observability_with_error_pp context pp_graph_error
      (E.on_exit
         (fun _ -> E.fail `Runtime_mismatch)
         (E.fail `Runtime_mismatch))

  type observer_read_error =
    [ `Disposed_observer | `Invalid_scope | `No_current_value
    | `Uninitialized_observer ]
  type stabilize_error = [ graph_error | `Observer_error of observer_error ]
  type time_error =
    [ graph_error | `Deadline_overflow | `Invalid_interval | `Past_deadline ]

  type 'a update =
    | Initialized of 'a
    | Changed of { old_value : 'a; new_value : 'a }

  type lifecycle = Active | Disposed | Invalid

  type timer_kind =
    | No_timer
    | Every of int
    | At of int
    | Ticks of int

  type timer = {
    runtime : Eta.Runtime_contract.t;
    kind : timer_kind;
    mutable last_sample : int;
    mutable demand : int;
    mutable start_pending : bool;
    mutable generation : int;
    mutable cancel : (unit -> unit) option;
    edge_timer :
      (Eta.Runtime_contract.t, observer_error) Edges.timer;
    source_node : Core.packed;
    reset : Eta.Runtime_contract.t -> int;
    refresh : Eta.Runtime_contract.t -> int -> unit;
    admit_refresh : unit -> bool;
    commit_refresh : unit -> unit;
    rollback_refresh : unit -> unit;
  }

  type 'a signal = {
    raw : 'a option Core.signal;
    timer : timer option;
  }

  type 'a var = {
    source : 'a option Core.var;
    mutable value : 'a;
    cutoff : 'a Cutoff.t;
    mutable updating : bool;
  }

  type 'a observer = {
    id : int;
    signal : 'a signal;
    cutoff : 'a Cutoff.t;
    mutable lifecycle : lifecycle;
    mutable current : 'a option;
    mutable published : 'a option;
    mutable edge_base : 'a option;
    demand : Core.demand;
    scope_demand : Core.demand option;
    mutable timer_demands : timer list;
    observed_attempt : int;
    mutable has_callback : bool;
    mutable callback_pending : bool;
    mutable deliver_pending : bool;
    mutable transferred : bool;
    finish_edge :
      (Edges.finish_reason -> (unit, observer_error) Edges.outcome) option;
    edge : 'a Edges.observer;
  }

  type 'a delivery = 'a Edges.delivery

  type packed_observer = O : 'a observer -> packed_observer

  type keyed_stats = {
    node_count : int;
    committed_child_count : int;
    reconciliation_count : int;
    input_key_comparison_count : int;
    input_diff_event_count : int;
    child_visit_count : int;
    provisional_addition_count : int;
    committed_addition_count : int;
    committed_removal_count : int;
    reconciliation_rollback_count : int;
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
    lane_waiter_count : int;
    lane_cancelled_waiter_count : int;
    keyed : keyed_stats;
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

  let graph = Core.create ()
  let execution = Execution.create ()
  let edge_execution = Edge_execution.create execution
  let edges = Edges.create edge_execution
  let edge_context : Eta.Spi.Expert.context option ref = ref None
  let delivering = ref false
  let delivering_fiber = ref None
  let edge_graph_error : graph_error option ref = ref None
  let edge_start_failed = ref false
  let sampling_timer_starts = ref false
  let initializers : (unit -> unit) list ref = ref []
  let scope_owners : (Core.scope * Core.packed) list ref = ref []
  let scope_parents : (Core.scope * Core.scope option) list ref = ref []
  let observers : packed_observer list ref = ref []
  let pending_observers : packed_observer list ref = ref []
  let pending_finishes :
      (unit -> (unit, observer_error) Edges.outcome) list ref =
    ref []
  let pending_edge_disposals : (unit -> unit) list ref = ref []
  let timers : timer list ref = ref []
  let timer_roots : Core.packed list ref = ref []
  let timer_nodes : (int, Core.handle * timer) Hashtbl.t =
    Hashtbl.create 8
  let compute_invalidators : (int, unit -> unit) Hashtbl.t =
    Hashtbl.create 32
  let custom_cutoff_nodes : (int, Core.handle) Hashtbl.t =
    Hashtbl.create 16
  let bind_nodes : (int, Core.handle) Hashtbl.t = Hashtbl.create 16
  let bind_evaluations : (int, Core.handle * int ref) Hashtbl.t =
    Hashtbl.create 16
  let next_observer_id = ref 0
  let pure_snapshot_commit_count = ref 0
  let callback_delivery_count = ref 0
  let dynamic_scope_invalidations = ref 0
  let recompute_count = ref 0
  let accounted_core_evaluations = ref 0
  let nodes_became_necessary = ref 0
  let nodes_became_unnecessary = ref 0
  let dead_nodes = ref 0
  let stabilization_attempts = ref 0

  let keyed =
    ref
      {
        node_count = 0;
        committed_child_count = 0;
        reconciliation_count = 0;
        input_key_comparison_count = 0;
        input_diff_event_count = 0;
        child_visit_count = 0;
        provisional_addition_count = 0;
        committed_addition_count = 0;
        committed_removal_count = 0;
        reconciliation_rollback_count = 0;
      }

  let ensure_context () = Execution.ensure_context execution
  let account_recomputations () =
    let evaluations = (Core.work graph).evaluations in
    recompute_count :=
      !recompute_count + (evaluations - !accounted_core_evaluations);
    accounted_core_evaluations := evaluations
  let signal_timers signal =
    let seen = Hashtbl.create 8 in
    let found = ref [] in
    let rec visit (Core.P node) =
      if not (Hashtbl.mem seen node.handle.slot) then (
        Hashtbl.add seen node.handle.slot ();
        (match Hashtbl.find_opt timer_nodes node.handle.slot with
        | Some (handle, timer) when handle = node.handle ->
            found := timer :: !found
        | Some _ | None -> ());
        Array.iter visit node.dependencies)
    in
    visit signal.raw.packed;
    !found
  let rec enqueue_reactivated (Core.P node as packed) =
    Array.iter
      (fun (Core.P dependency as packed) ->
        if Array.length dependency.dependencies > 0 then
          enqueue_reactivated packed)
      node.dependencies;
    if Array.length node.dependencies > 0 then Core.enqueue packed
  let necessary_count () =
    let count = ref 0 in
    for slot = 0 to graph.slot_count - 1 do
      match Core.slot_contents graph.slots.(slot) with
      | Some (Core.P node) when node.necessary -> incr count
      | Some _ | None -> ()
    done;
    !count
  let suppress cutoff old candidate =
    Cutoff.suppress cutoff ~published:old ~candidate
  let cutoff_or_default = Option.value ~default:Cutoff.phys_equal
  let option_cutoff cutoff old candidate =
    match old, candidate with
    | Some old, Some candidate -> suppress cutoff old candidate
    | None, None -> true
    | None, Some _ | Some _, None -> false
  let value_exn = function
    | Some value -> value
    | None -> failwith "Eta_signal: uninitialized dependency"
  let raw_value signal = Core.value signal.raw |> value_exn
  let check_signal signal =
    if not (Core.validate_handle signal.raw) then
      match signal.raw.node.scope with
      | Some _ -> raise (Graph_error `Invalid_scope)
      | None ->
          let slot = signal.raw.handle.slot in
          let entry = graph.slots.(slot) in
          if entry.generation <> signal.raw.handle.generation then
            raise (Graph_error `Invalid_scope);
          let retained = ref 0 in
          for index = 0 to graph.free_length - 1 do
            if graph.free.(index) <> slot then (
              graph.free.(!retained) <- graph.free.(index);
              incr retained)
          done;
          graph.free_length <- !retained;
          entry.is_free <- false;
          Core.set_slot_contents entry (Some signal.raw.packed)

  let make_raw ?cutoff:cutoff_arg ~height ~dependencies compute =
    if (graph.running || !delivering) && graph.current_scope = None then
      raise (Graph_error `Ambiguous_scope);
    let cutoff = cutoff_or_default cutoff_arg in
    let computed_in = ref (-1) in
    let computed = ref None in
    let duplicate_evaluation = ref false in
    let compute_once () =
      if !computed_in = graph.pass then (
        duplicate_evaluation := true;
        Option.get !computed)
      else
        let value = compute () in
        computed_in := graph.pass;
        computed := Some value;
        duplicate_evaluation := false;
        value
    in
    let inherited_scope =
      if Option.is_some graph.current_scope then None
      else
        Array.fold_left
          (fun inherited (Core.P dependency) ->
            match inherited, dependency.scope with
            | inherited, None -> inherited
            | None, Some scope -> Some scope
            | Some left, Some right when left == right -> inherited
            | Some _, Some _ -> raise (Graph_error `Ambiguous_scope))
          None dependencies
    in
    let create () =
      let scoped =
        Option.is_some graph.current_scope || Option.is_some inherited_scope
      in
      Core.make_node graph ~height:(if scoped then height + 1 else height)
        ~dependencies
        ~compute:(fun () ->
          if
            Array.exists
              (fun (Core.P dependency) ->
                Option.is_none
                  (Obj.magic dependency.current : Obj.t option))
              dependencies
          then None
          else Some (compute_once ()))
        ~cutoff:(fun old candidate ->
          !duplicate_evaluation || option_cutoff cutoff old candidate)
        ~initial:None
    in
    let raw =
      match inherited_scope with
      | None -> create ()
      | Some scope -> Core.with_scope graph scope create
    in
    if cutoff != Cutoff.phys_equal then
      Hashtbl.replace custom_cutoff_nodes raw.handle.slot raw.handle;
    let weak_raw = Weak.create 1 in
    Weak.set weak_raw 0 (Some raw.packed);
    let invalidate () =
      if !computed_in = graph.pass then (
        match Weak.get weak_raw 0 with
        | Some (Core.P node) -> node.queued_in <- -1
        | None -> ());
      computed_in := -1;
      duplicate_evaluation := false
    in
    Hashtbl.replace compute_invalidators raw.handle.slot invalidate;
    Array.iter
      (fun (Core.P dependency) ->
        let own, others =
          List.partition
            (fun (Core.P candidate) ->
              candidate.handle = raw.node.handle)
            dependency.dependents
        in
        dependency.dependents <- others @ own;
        dependency.change_listeners <-
          (fun _ ->
            if !computed_in = graph.pass then invalidate ())
          :: dependency.change_listeners)
      dependencies;
    initializers :=
      (fun () ->
        if Core.validate_handle raw
           && raw.node.necessary && Core.value raw = None then
          Core.enqueue (Core.P raw.node))
      :: !initializers;
    raw

  let const value =
    Execution.sync execution @@ fun () ->
    if (graph.running || !delivering) && graph.current_scope = None then
      raise (Graph_error `Ambiguous_scope);
    let raw =
      Core.make_node graph ~height:0 ~dependencies:[||]
        ~compute:(fun () -> Some value)
        ~cutoff:(fun old next -> old <> None && next <> None)
        ~initial:None
    in
    initializers :=
      (fun () ->
        if Core.validate_handle raw
           && raw.node.necessary && Core.value raw = None then
          Core.enqueue (Core.P raw.node))
      :: !initializers;
    { raw; timer = None }

  let map ?cutoff f child =
    Execution.sync execution @@ fun () ->
    check_signal child;
    let result =
      {
      raw =
        make_raw ?cutoff ~height:(child.raw.node.height + 1)
          ~dependencies:[| Core.P child.raw.node |]
          (fun () -> f (raw_value child));
      timer = child.timer;
      }
    in
    if Option.is_some result.timer then
      timer_roots := result.raw.packed :: !timer_roots;
    result

  let mapn ?cutoff dependencies compute =
    Array.iter check_signal dependencies;
    let height =
      Array.fold_left
        (fun height signal -> max height signal.raw.node.height) 0 dependencies
    in
    {
      raw =
        make_raw ?cutoff ~height:(height + 1)
          ~dependencies:
            (Array.map (fun signal -> Core.P signal.raw.node) dependencies)
          compute;
      timer =
        Array.fold_left
          (fun found signal ->
            match found with Some _ -> found | None -> signal.timer)
          None dependencies;
    }

  let map2 ?cutoff f a b =
    Execution.sync execution @@ fun () ->
    check_signal a; check_signal b;
    {
      raw = make_raw ?cutoff
          ~height:(1 + max a.raw.node.height b.raw.node.height)
          ~dependencies:[| Core.P a.raw.node; Core.P b.raw.node |]
          (fun () -> f (raw_value a) (raw_value b));
      timer = (match a.timer with Some _ -> a.timer | None -> b.timer);
    }
  let map3 ?cutoff f a b c =
    Execution.sync execution @@ fun () ->
    check_signal a; check_signal b; check_signal c;
    {
      raw = make_raw ?cutoff
          ~height:(1 + max a.raw.node.height (max b.raw.node.height c.raw.node.height))
          ~dependencies:[| Core.P a.raw.node; Core.P b.raw.node; Core.P c.raw.node |]
          (fun () -> f (raw_value a) (raw_value b) (raw_value c));
      timer = (match a.timer, b.timer with Some _ as t, _ | None, (Some _ as t) -> t | None, None -> c.timer);
    }
  let map4 ?cutoff f a b c d =
    Execution.sync execution @@ fun () ->
    check_signal a; check_signal b; check_signal c; check_signal d;
    let height = List.fold_left max 0 [a.raw.node.height; b.raw.node.height; c.raw.node.height; d.raw.node.height] in
    { raw = make_raw ?cutoff ~height:(height + 1)
        ~dependencies:[| Core.P a.raw.node; Core.P b.raw.node; Core.P c.raw.node; Core.P d.raw.node |]
        (fun () -> f (raw_value a) (raw_value b) (raw_value c) (raw_value d));
      timer = List.find_map Fun.id [a.timer; b.timer; c.timer; d.timer] }
  let map5 ?cutoff f a b c d e =
    Execution.sync execution @@ fun () ->
    let deps = [| Core.P a.raw.node; Core.P b.raw.node; Core.P c.raw.node; Core.P d.raw.node; Core.P e.raw.node |] in
    let height = Array.fold_left (fun h (Core.P n) -> max h n.height) 0 deps in
    { raw = make_raw ?cutoff ~height:(height + 1) ~dependencies:deps
        (fun () -> f (raw_value a) (raw_value b) (raw_value c) (raw_value d) (raw_value e));
      timer = List.find_map Fun.id [a.timer; b.timer; c.timer; d.timer; e.timer] }
  let map6 ?cutoff f a b c d e g =
    Execution.sync execution @@ fun () ->
    let deps = [| Core.P a.raw.node; Core.P b.raw.node; Core.P c.raw.node; Core.P d.raw.node; Core.P e.raw.node; Core.P g.raw.node |] in
    let height = Array.fold_left (fun h (Core.P n) -> max h n.height) 0 deps in
    { raw = make_raw ?cutoff ~height:(height + 1) ~dependencies:deps
        (fun () -> f (raw_value a) (raw_value b) (raw_value c) (raw_value d) (raw_value e) (raw_value g));
      timer = List.find_map Fun.id [a.timer; b.timer; c.timer; d.timer; e.timer; g.timer] }
  let map7 ?cutoff f a b c d e g h =
    Execution.sync execution @@ fun () ->
    let deps = [| Core.P a.raw.node; Core.P b.raw.node; Core.P c.raw.node; Core.P d.raw.node; Core.P e.raw.node; Core.P g.raw.node; Core.P h.raw.node |] in
    let height = Array.fold_left (fun x (Core.P n) -> max x n.height) 0 deps in
    { raw = make_raw ?cutoff ~height:(height + 1) ~dependencies:deps
        (fun () -> f (raw_value a) (raw_value b) (raw_value c) (raw_value d) (raw_value e) (raw_value g) (raw_value h));
      timer = List.find_map Fun.id [a.timer;b.timer;c.timer;d.timer;e.timer;g.timer;h.timer] }
  let map8 ?cutoff f a b c d e g h i =
    Execution.sync execution @@ fun () ->
    let deps = [| Core.P a.raw.node; Core.P b.raw.node; Core.P c.raw.node; Core.P d.raw.node; Core.P e.raw.node; Core.P g.raw.node; Core.P h.raw.node; Core.P i.raw.node |] in
    let height = Array.fold_left (fun x (Core.P n) -> max x n.height) 0 deps in
    { raw = make_raw ?cutoff ~height:(height + 1) ~dependencies:deps
        (fun () -> f (raw_value a) (raw_value b) (raw_value c) (raw_value d) (raw_value e) (raw_value g) (raw_value h) (raw_value i));
      timer = List.find_map Fun.id [a.timer;b.timer;c.timer;d.timer;e.timer;g.timer;h.timer;i.timer] }
  let map9 ?cutoff f a b c d e g h i j =
    Execution.sync execution @@ fun () ->
    let deps = [| Core.P a.raw.node; Core.P b.raw.node; Core.P c.raw.node; Core.P d.raw.node; Core.P e.raw.node; Core.P g.raw.node; Core.P h.raw.node; Core.P i.raw.node; Core.P j.raw.node |] in
    let height = Array.fold_left (fun x (Core.P n) -> max x n.height) 0 deps in
    { raw = make_raw ?cutoff ~height:(height + 1) ~dependencies:deps
        (fun () -> f (raw_value a) (raw_value b) (raw_value c) (raw_value d) (raw_value e) (raw_value g) (raw_value h) (raw_value i) (raw_value j));
      timer = List.find_map Fun.id [a.timer;b.timer;c.timer;d.timer;e.timer;g.timer;h.timer;i.timer;j.timer] }

  let all ?cutoff signals =
    Execution.sync execution @@ fun () ->
    let dependencies = Array.of_list signals in
    mapn ?cutoff dependencies (fun () -> List.map raw_value signals)

  let reduce_balanced ?cutoff ~identity ~combine signals =
    Execution.sync execution @@ fun () ->
    let signals = Array.copy signals in
    let rec build first length =
      if length = 0 then const identity
      else if length = 1 then signals.(first)
      else
        let left_length = length / 2 in
        let left = build first left_length in
        let right = build (first + left_length) (length - left_length) in
        map2 ~cutoff:Cutoff.never combine left right
    in
    match Array.length signals with
    | 0 -> const identity
    | 1 -> map ?cutoff Fun.id signals.(0)
    | length ->
        let root = build 0 length in
        map ?cutoff Fun.id root

  module Var = struct
    type 'a t = 'a var

    let create ?cutoff value =
      Execution.sync execution @@ fun () ->
      let cutoff = cutoff_or_default cutoff in
      {
        source =
          Core.var ~cutoff:(fun _ _ -> false) graph (Some value);
        value;
        cutoff;
        updating = false;
      }

    let value var =
      Execution.sync execution @@ fun () ->
      if graph.running then raise (Graph_error `Ambiguous_scope);
      var.value

    let watch var =
      Execution.sync execution @@ fun () ->
      let source = Core.watch var.source in
      {
        raw =
          make_raw ~cutoff:var.cutoff ~height:(source.node.height + 1)
            ~dependencies:[| source.packed |]
            (fun () -> Core.value source |> value_exn);
        timer = None;
      }

    let set (var : 'a t) value =
      Execution.run execution @@ fun _checkpoint ->
      if var.updating then Error `Reentrant_update
      else (
        Core.set graph var.source (Some value);
        var.value <- value;
        Ok ())

    let update_effect (var : 'a t) f =
      let open Eta.Syntax in
      let operation =
        let* current =
          Execution.run execution @@ fun _checkpoint ->
          if var.updating then Error `Reentrant_update
          else (
            var.updating <- true;
            Ok var.value)
        in
        f current
      in
      E.on_exit
        (function
          | Eta.Exit.Ok value ->
              Execution.run execution @@ fun _checkpoint ->
              Core.set graph var.source (Some value);
              var.value <- value;
              var.updating <- false;
              Ok ()
          | Eta.Exit.Error _ ->
              Execution.run execution @@ fun _checkpoint ->
              var.updating <- false;
              Ok ())
        operation
  end

  let unlink_queued_node (Core.P target) =
    if target.queued_in = graph.pass then (
      let removed = ref false in
      for height = 0 to Array.length graph.heads - 1 do
        if not !removed then (
          let previous = ref None in
          let slot = ref graph.heads.(height) in
          while !slot <> -1 && not !removed do
            match Core.slot_contents graph.slots.(!slot) with
            | None -> slot := -1
            | Some (Core.P node as packed) ->
                let next = node.queue_next in
                if node.handle = target.handle then (
                  (match !previous with
                  | None -> graph.heads.(height) <- next
                  | Some (Core.P previous) ->
                      previous.queue_next <- next);
                  if graph.tails.(height) = node.handle.slot then
                    graph.tails.(height) <-
                      (match !previous with
                      | None -> -1
                      | Some (Core.P previous) -> previous.handle.slot);
                  node.queue_next <- -1;
                  node.queued_in <- -1;
                  removed := true)
                else (
                  previous := Some packed;
                  slot := next)
          done)
      done)

  let unlink_unnecessary_queued () =
    for slot = 0 to graph.slot_count - 1 do
      match Core.slot_contents graph.slots.(slot) with
      | Some (Core.P node as packed) when not node.necessary ->
          unlink_queued_node packed
      | Some _ | None -> ()
    done

  let rec ensure_parent_height ?(current = false)
      (Core.P node as packed) minimum =
    if node.height < minimum then (
      if not current then unlink_queued_node packed;
      node.height <- minimum;
      Core.ensure_height graph minimum;
      if not current then (
        node.queued_in <- -1;
        if node.necessary then Core.enqueue packed);
      List.iter
        (fun parent -> ensure_parent_height parent (minimum + 1))
        node.dependents)

  let bind ?cutoff ~f source =
    Execution.sync execution @@ fun () ->
    check_signal source;
    let selected = ref None in
    let inner = ref None in
    let scope = ref None in
    let owner = ref None in
    let evaluated_in = ref (-1) in
    let compute () =
      evaluated_in := graph.pass;
      try
      let source_value =
        match Core.value source.raw with
        | Some value -> value
        | None -> raise Deferred_source
      in
      let changed =
        match !selected with
        | None -> true
        | Some old -> old != source_value
      in
      if changed then (
        let old_selected = !selected in
        let old_inner = !inner in
        let old_scope = !scope in
        let parent_scope =
          match !owner with
          | Some owner -> owner.raw.node.scope
          | None -> graph.current_scope
        in
        let fresh_scope = { Core.valid = true; slot_head = -1 } in
        scope_parents := (fresh_scope, parent_scope) :: !scope_parents;
        let fresh =
          Core.with_scope graph fresh_scope (fun () -> f source_value)
        in
        check_signal fresh;
        let rec scope_is_ancestor candidate = function
          | None -> false
          | Some scope when scope == candidate -> true
          | Some scope ->
              scope_is_ancestor candidate
                (List.find_map
                   (fun ((child : Core.scope), parent) ->
                     if child == scope then Some parent else None)
                   !scope_parents
                |> Option.join)
        in
        let seen_scopes = Hashtbl.create 8 in
        let rec validate_scopes (Core.P node) =
          if not (Hashtbl.mem seen_scopes node.handle.slot) then (
            Hashtbl.add seen_scopes node.handle.slot ();
            (match node.scope with
            | None -> ()
            | Some candidate ->
                if
                  not candidate.valid
                  || not
                       (candidate == fresh_scope
                       || scope_is_ancestor candidate parent_scope)
                then raise (Graph_error `Invalid_scope);
                Array.iter validate_scopes node.dependencies))
        in
        validate_scopes fresh.raw.packed;
        let owner_handle = (Option.get !owner).raw.handle in
        let seen = Hashtbl.create 8 in
        let rec reaches_owner (Core.P node) =
          if node.handle = owner_handle then true
          else if Hashtbl.mem seen node.handle.slot then false
          else (
            Hashtbl.add seen node.handle.slot ();
            Array.exists reaches_owner node.dependencies)
        in
        if reaches_owner fresh.raw.packed then (
          let seen_pending = Hashtbl.create 8 in
          let rec has_pending_bind (Core.P node) =
            if Hashtbl.mem seen_pending node.handle.slot then false
            else (
              Hashtbl.add seen_pending node.handle.slot ();
              match Hashtbl.find_opt bind_evaluations node.handle.slot with
              | Some (handle, pass)
                when handle = node.handle
                     && !pass <> graph.pass
                     && node.queued_in = graph.pass ->
                  true
              | Some _ | None ->
                  Array.exists has_pending_bind node.dependencies)
          in
          if has_pending_bind fresh.raw.packed then
            raise Deferred_bind
          else raise (Graph_error `Cycle));
        let packed_owner = Core.P (Option.get !owner).raw.node in
        Option.iter
          (fun old ->
            Core.detach packed_owner (Core.P old.raw.node);
            if (Option.get !owner).raw.node.necessary then
              Core.deactivate (Core.P old.raw.node))
          old_inner;
        Core.attach packed_owner (Core.P fresh.raw.node);
        if
          Option.is_some fresh.raw.node.scope
          && Hashtbl.find_opt bind_nodes fresh.raw.handle.slot
             = Some fresh.raw.handle
        then
          ensure_parent_height ~current:true packed_owner
            (fresh.raw.node.height + 1);
        Option.iter
          (fun invalidate ->
            fresh.raw.node.change_listeners <-
              (fun _ -> invalidate ())
              :: fresh.raw.node.change_listeners)
          (Hashtbl.find_opt compute_invalidators
             (Option.get !owner).raw.handle.slot);
        scope_owners := (fresh_scope, packed_owner) :: !scope_owners;
        if (Option.get !owner).raw.node.necessary then (
          Core.activate (Core.P fresh.raw.node);
          if Option.is_none fresh.timer then
            List.iter (fun initialize -> initialize ()) !initializers);
        Option.iter
          (fun (old_scope : Core.scope) ->
            incr dynamic_scope_invalidations;
            let rec retire scope =
              List.iter retire
                (List.filter_map
                   (fun ((child : Core.scope), parent) ->
                     match parent with
                     | Some parent when parent == scope && child.valid ->
                         Some child
                     | None | Some _ -> None)
                   !scope_parents);
              let rec retire_slots count slot =
                if slot = -1 then count
                else
                  match Core.slot_contents graph.slots.(slot) with
                  | Some (Core.P node as packed) ->
                      let next = node.scope_next in
                      (match node.scope with
                      | Some owner when owner == scope ->
                          unlink_queued_node packed;
                          Core.retire_packed graph packed;
                          retire_slots (count + 1) next
                      | None | Some _ -> count)
                  | None -> count
              in
              dead_nodes := !dead_nodes + retire_slots 0 scope.slot_head;
              scope.valid <- false
            in
            retire old_scope)
          old_scope;
        selected := Some source_value;
        inner := Some fresh;
        scope := Some fresh_scope;
        Core.push_capsule graph
          {
            Core.rollback_capsule =
              (fun () ->
                Core.detach packed_owner (Core.P fresh.raw.node);
                if (Option.get !owner).raw.node.necessary then
                  Core.deactivate (Core.P fresh.raw.node);
                Option.iter
                  (fun old ->
                    Core.attach packed_owner (Core.P old.raw.node);
                    if (Option.get !owner).raw.node.necessary then
                      Core.activate (Core.P old.raw.node))
                  old_inner;
                selected := old_selected;
                inner := old_inner;
                scope := old_scope);
            cleanup_capsule = (fun () -> ());
          });
      (match Core.value (Option.get !inner).raw with
      | Some _ as value -> value
      | None ->
          let owner = Option.get !owner in
          owner.raw.node.queued_in <- -1;
          Core.value owner.raw)
      with Deferred_bind ->
        let owner = Option.get !owner in
        owner.raw.node.queued_in <- -1;
        Core.enqueue owner.raw.packed;
        Option.bind !inner (fun signal -> Core.value signal.raw)
      | Deferred_source ->
        let owner = Option.get !owner in
        owner.raw.node.queued_in <- -1;
        Option.bind !inner (fun signal -> Core.value signal.raw)
    in
    let selected_cutoff = cutoff_or_default cutoff in
    let raw =
      Core.make_node graph ~height:(source.raw.node.height + 2)
        ~dependencies:[| Core.P source.raw.node |] ~compute
        ~cutoff:(option_cutoff selected_cutoff) ~initial:None
    in
    let weak_raw = Weak.create 1 in
    Weak.set weak_raw 0 (Some raw.packed);
    Hashtbl.replace compute_invalidators raw.handle.slot (fun () ->
        match Weak.get weak_raw 0 with
        | Some (Core.P node) -> node.queued_in <- -1
        | None -> ());
    Hashtbl.replace bind_nodes raw.handle.slot raw.handle;
    Hashtbl.replace bind_evaluations raw.handle.slot
      (raw.handle, evaluated_in);
    initializers :=
      (fun () ->
        if Core.validate_handle raw
           && raw.node.necessary && Core.value raw = None then
          Core.enqueue (Core.P raw.node))
      :: !initializers;
    let result = { raw; timer = source.timer }
    in
    owner := Some result;
    result

  let checked_next name counter =
    if !counter = max_int then raise (Graph_error (`Counter_overflow name));
    incr counter;
    !counter

  let publish_observer observer value =
    if observer.lifecycle = Active then (
      if observer.callback_pending then (
        observer.current <- Some value;
        observer.published <- Some value;
        match observer.edge_base with
        | Some base when base == value ->
            observer.callback_pending <- false;
            observer.deliver_pending <- false;
            Edges.publish edges observer.edge value
        | None | Some _ ->
            observer.deliver_pending <- true;
            Edges.publish edges observer.edge value)
      else
      match observer.published with
      | Some old when suppress observer.cutoff old value ->
          observer.current <- Some value;
          observer.published <- Some value;
          observer.callback_pending <- false;
          observer.deliver_pending <- false;
          Edges.publish edges observer.edge value
      | _ ->
          observer.current <- Some value;
          observer.published <- Some value;
          observer.callback_pending <- observer.has_callback;
          observer.deliver_pending <- true;
          Edges.publish edges observer.edge value)

  let signal_depends_on signal dependency =
    let target = dependency.raw.handle in
    let seen = Hashtbl.create 8 in
    let rec visit (Core.P node) =
      if node.handle = target then true
      else if Hashtbl.mem seen node.handle.slot then false
      else (
        Hashtbl.add seen node.handle.slot ();
        Array.exists visit node.dependencies)
    in
    Array.exists visit signal.raw.node.dependencies

  let observer_order observers =
    let rec loop ordered remaining =
      match remaining with
      | [] -> List.rev ordered
      | _ ->
          let ready =
            List.filter
              (fun (O candidate) ->
                not
                  (List.exists
                     (fun (O predecessor) ->
                       signal_depends_on candidate.signal predecessor.signal)
                     remaining))
              remaining
          in
          let selected =
            List.fold_left
              (fun best (O observer as packed) ->
                match best with
                | None -> Some packed
                | Some (O current) ->
                    if observer.id < current.id then Some packed else best)
              None ready
            |> Option.get
          in
          let O selected_observer = selected in
          loop (selected :: ordered)
            (List.filter
               (fun (O observer) -> observer.id <> selected_observer.id)
               remaining)
    in
    loop [] observers

  let settle_invalid_observers () =
    List.iter
      (fun (O observer) ->
        if observer.lifecycle = Active
           && not (Core.validate_handle observer.signal.raw)
        then (
          let necessary_before = necessary_count () in
          observer.lifecycle <- Invalid;
          observer.current <- None;
          observer.published <- None;
          observer.edge_base <- None;
          observer.callback_pending <- false;
          Core.release observer.demand;
          Option.iter Core.release observer.scope_demand;
          unlink_unnecessary_queued ();
          List.iter
            (fun (timer : timer) ->
              timer.demand <- max 0 (timer.demand - 1);
              if timer.demand = 0 then (
                timer.start_pending <- false;
                Edges.set_timer_demand edges timer.edge_timer false))
            observer.timer_demands;
          incr dynamic_scope_invalidations;
          Option.iter
            (fun finish ->
              pending_finishes :=
                (fun () -> finish Edges.Invalid_scope)
                :: !pending_finishes)
            observer.finish_edge;
          Edges.invalidate edges observer.edge;
          nodes_became_unnecessary :=
            !nodes_became_unnecessary
            + max 0 (necessary_before - necessary_count ())))
      (!pending_observers @ !observers);
    ()

  let reconcile_timer_demands runtime =
    List.iter
      (fun (O observer) ->
        if observer.lifecycle = Active then (
          let next = signal_timers observer.signal in
          List.iter
            (fun (timer : timer) ->
              if not (List.exists (( == ) timer) next) then (
                timer.demand <- max 0 (timer.demand - 1);
                if timer.demand = 0 then (
                  timer.start_pending <- false;
                  Edges.set_timer_demand edges timer.edge_timer false)))
            observer.timer_demands;
          List.iter
            (fun (timer : timer) ->
              if
                not
                  (Eta.Runtime_contract.same_runtime runtime timer.runtime)
              then raise (Graph_error `Runtime_mismatch);
              if
                not
                  (List.exists (( == ) timer) observer.timer_demands)
              then (
                timer.demand <- timer.demand + 1;
                if timer.demand = 1 then (
                  timer.start_pending <- true;
                  Edges.set_timer_demand edges timer.edge_timer true)))
            next;
          observer.timer_demands <- next))
      !observers

  let collect_observers () =
    let ordered =
      observer_order
        (List.filter
           (fun (O observer) -> observer.lifecycle = Active)
           !observers)
    in
    List.iter
      (fun (O observer) ->
        if observer.lifecycle = Active then
          match Core.value observer.signal.raw with
          | Some value -> publish_observer observer value
          | None -> ())
      ordered;
    List.map
      (fun (O observer) -> Edges.Observer observer.edge)
      ordered

  let edge_outcome effect =
    let context = Option.get !edge_context in
    try
      match Eta.Spi.Expert.eval context effect with
      | Eta.Exit.Ok value -> Edges.Success value
      | Eta.Exit.Error (Eta.Cause.Fail error) ->
          Edges.Failure (Edges.Typed_failure error)
      | Eta.Exit.Error (Eta.Cause.Die die) ->
          (match die.Eta.Cause.exn with
          | Graph_error error -> edge_graph_error := Some error
          | _ -> ());
          Edges.Failure (Edges.Defect die.Eta.Cause.exn)
      | Eta.Exit.Error cause ->
          Edges.Failure
            (Edges.Interrupted
               (Failure
                  (Eta.Cause.pretty
                     (Format.asprintf "%a" Observer_error.pp)
                     cause)))
    with exn ->
      let contract = Eta.Spi.Expert.contract context in
      if
        match exn with
        | Graph_error error ->
            edge_graph_error := Some error;
            true
        | _ -> false
      then Edges.Failure (Edges.Defect exn)
      else if Option.is_some (contract.Eta.Runtime_contract.cancellation_reason exn)
      then Edges.Failure (Edges.Interrupted exn)
      else Edges.Failure (Edges.Defect exn)

  let edge_outcome_effect make =
    try edge_outcome (make ())
    with
    | Graph_error error as exn ->
        edge_graph_error := Some error;
        Edges.Failure (Edges.Defect exn)
    | exn -> Edges.Failure (Edges.Defect exn)

  let edge_update = function
    | Edges.Initialized value -> Initialized value
    | Edges.Changed (old_value, new_value) ->
        Changed { old_value; new_value }

  let prepare_timer_starts_now runtime =
    sampling_timer_starts := true;
    Fun.protect
      ~finally:(fun () -> sampling_timer_starts := false)
      (fun () ->
        let attempted = ref [] in
        let refreshed = ref false in
        try
          List.iter
            (fun (timer : timer) ->
              if timer.start_pending && timer.demand > 0 then (
                attempted := timer :: !attempted;
                let now = timer.reset runtime in
                if timer.demand > 0 then (
                  match timer.kind with
                  | Every _ | At _ ->
                      timer.refresh runtime now;
                      refreshed := true
                  | Ticks _ | No_timer -> ());
                if timer.demand > 0 then timer.start_pending <- false
                else timer.rollback_refresh ()))
              (List.rev !timers);
          (!refreshed, !attempted)
        with exn ->
          List.iter (fun timer -> timer.rollback_refresh ()) !attempted;
          raise exn)

  let run_edge_plan plan =
    Eta.Spi.Expert.make ~leaf_name:"eta_signal.post_commit" @@ fun context ->
    let contract = Eta.Spi.Expert.contract context in
    let previous_context = !edge_context in
    let previous_contract = edge_execution.Edge_execution.contract in
    edge_context := Some context;
    edge_execution.Edge_execution.contract <- Some contract;
    let previous_delivering = !delivering in
    let previous_delivering_fiber = !delivering_fiber in
    delivering := true;
    delivering_fiber := Some (contract.Eta.Runtime_contract.current_fiber_id ());
    let finish () =
      delivering := previous_delivering;
      delivering_fiber := previous_delivering_fiber;
      edge_execution.Edge_execution.contract <- previous_contract;
      edge_context := previous_context
    in
    Fun.protect ~finally:finish @@ fun () ->
    let disposals = List.rev !pending_edge_disposals in
    pending_edge_disposals := [];
    List.iter (fun dispose -> dispose ()) disposals;
    let failure = function
      | Edges.Typed_failure error ->
          Eta.Exit.Error (Eta.Cause.Fail (`Observer_error error))
      | Edges.Defect exn -> Eta.Spi.Expert.exit_of_exn context exn
      | Edges.Interrupted exn -> raise exn
    in
    let finalizer_failure failures =
      let diagnostic = function
        | Edges.Typed_failure error ->
            Eta.Cause.Finalizer.Fail
              {
                error;
                rendered = Format.asprintf "%a" Observer_error.pp error;
              }
        | Edges.Defect exn | Edges.Interrupted exn ->
            (match Eta.Spi.Expert.exit_of_exn context exn with
            | Eta.Exit.Error cause ->
                Eta.Cause.finalizer_of_cause Observer_error.pp cause
            | Eta.Exit.Ok _ -> assert false)
      in
      let diagnostics = List.map diagnostic failures in
      let finalizer =
        match diagnostics with
        | [ failure ] -> failure
        | _ -> Eta.Cause.Finalizer.Sequential diagnostics
      in
      Eta.Exit.Error (Eta.Cause.Finalizer finalizer)
    in
    edge_graph_error := None;
    let finishes = List.rev !pending_finishes in
    pending_finishes := [];
    List.iter (fun finish -> ignore (finish ())) finishes;
    let had_callback_delivery =
      List.exists
        (fun (O observer) ->
          observer.has_callback && observer.callback_pending)
        !observers
    in
    ignore (prepare_timer_starts_now contract);
    edge_start_failed := false;
    let result = Edges.run edges ~runtime:contract ~plan in
    if
      Result.is_ok result
      && Edges.queued_timer_count edges > 0
      && List.for_all (fun (timer : timer) -> timer.demand = 0) !timers
    then
      ignore
        (Edges.run edges ~runtime:contract ~plan:[] :
          (unit, observer_error Edges.run_error) result);
    (match result with
    | Ok () -> ()
    | Error _ ->
        List.iter
          (fun (O observer) ->
            if observer.lifecycle = Active && not observer.transferred then (
              observer.lifecycle <- Disposed;
              Core.release observer.demand;
              Option.iter Core.release observer.scope_demand;
              List.iter
                (fun (timer : timer) ->
                  timer.demand <- max 0 (timer.demand - 1);
                  if timer.demand = 0 then (
                    timer.start_pending <- false;
                    Edges.set_timer_demand edges timer.edge_timer false))
                observer.timer_demands;
              Edges.dispose edges observer.edge))
          !pending_observers;
        pending_observers :=
          List.filter
            (fun (O observer) -> observer.lifecycle = Active)
            !pending_observers;
        unlink_unnecessary_queued ();
        ignore
          (Edges.drain_cleanup edges :
            (unit, observer_error Edges.run_error) result));
    match !edge_graph_error, result with
    | Some error, _ ->
        Eta.Exit.Error (Eta.Cause.Fail (error :> stabilize_error))
    | None, Ok () ->
        if had_callback_delivery then incr callback_delivery_count;
        Eta.Exit.Ok ()
    | None, Error Edges.Runtime_mismatch ->
        Eta.Exit.Error
          (Eta.Cause.Fail (`Runtime_mismatch :> stabilize_error))
    | None, Error (Edges.Callback_failure error) -> failure error
    | None, Error (Edges.Cleanup_failures (error :: _))
      when !edge_start_failed -> failure error
    | None, Error (Edges.Cleanup_failures errors) -> finalizer_failure errors

  let observe_with ?cutoff ?on_finish signal edge_callback =
    if not (Core.validate_handle signal.raw) then Error `Invalid_scope
    else
      let id = checked_next "observer id" next_observer_id in
      let necessary_before = necessary_count () in
      let was_necessary = signal.raw.node.necessary in
      let demand = Core.demand signal.raw in
      if not was_necessary then enqueue_reactivated signal.raw.packed;
      let scope_demand =
        match signal.raw.node.scope with
        | None -> None
        | Some scope ->
            List.find_map
              (fun (candidate, owner) ->
                if candidate == scope then (
                  Core.activate owner;
                  Some owner)
                else None)
              !scope_owners
      in
      let finish =
        Option.map
          (fun hook ->
            let claimed = ref false in
            fun reason ->
              if !claimed then Edges.Success ()
              else (
                claimed := true;
                edge_outcome
                  (E.sync (fun () ->
                     hook
                       (match reason with
                       | Edges.Disposed -> `Disposed
                       | Edges.Invalid_scope -> `Invalid_scope)))))
          on_finish
      in
      let observer_ref = ref None in
      let edge =
        Edges.observe edges ?finish @@ fun delivery ->
        let observer = Option.get !observer_ref in
        if not observer.deliver_pending then Edges.Success ()
        else
          match edge_callback delivery with
          | Edges.Success () as success ->
              observer.deliver_pending <- false;
              observer.callback_pending <- false;
              observer.edge_base <- observer.current;
              success
          | Edges.Failure _ as failure -> failure
      in
      let timer_demands = signal_timers signal in
      let observer =
        {
          id;
          signal;
          cutoff = cutoff_or_default cutoff;
          lifecycle = Active;
          current = None;
          published = None;
          edge_base = None;
          demand;
          scope_demand;
          timer_demands;
          observed_attempt = !stabilization_attempts;
          has_callback = false;
          callback_pending = false;
          deliver_pending = false;
          transferred = false;
          finish_edge = finish;
          edge;
        }
      in
      observer_ref := Some observer;
      pending_observers := O observer :: !pending_observers;
      nodes_became_necessary :=
        !nodes_became_necessary
        + max 0 (necessary_count () - necessary_before);
      List.iter
        (fun (timer : timer) ->
          timer.demand <- timer.demand + 1;
          if timer.demand = 1 then (
            timer.start_pending <- true;
            Edges.activate_timer_registration edges timer.edge_timer edge))
        timer_demands;
      Ok observer

  let transfer_observer observer =
    pending_observers :=
      List.filter
        (fun (O pending) -> pending.id <> observer.id)
        !pending_observers;
    observer.transferred <- true;
    observers := O observer :: !observers

  let transfer_pending_observers () =
    List.iter
      (fun (O observer) ->
        if observer.lifecycle = Active then transfer_observer observer)
      (List.rev !pending_observers)

  let abandon_observer_now observer =
    if observer.lifecycle <> Disposed then (
        observer.lifecycle <- Disposed;
        pending_observers :=
          List.filter
            (fun (O candidate) -> candidate.id <> observer.id)
            !pending_observers;
        observers :=
          List.filter
            (fun (O candidate) -> candidate.id <> observer.id)
            !observers;
        Core.release observer.demand;
        Option.iter Core.release observer.scope_demand;
        let aborted_timer = ref false in
        List.iter
          (fun (timer : timer) ->
            timer.demand <- max 0 (timer.demand - 1);
            if timer.demand = 0 then (
              timer.start_pending <- false;
              aborted_timer := true;
              pending_edge_disposals :=
                (fun () ->
                  Edges.abort_timer_registration edges timer.edge_timer
                    observer.edge Edges.Disposed)
                :: !pending_edge_disposals))
          observer.timer_demands;
        unlink_unnecessary_queued ();
        if not !aborted_timer then
          pending_edge_disposals :=
            (fun () -> Edges.dispose edges observer.edge)
            :: !pending_edge_disposals)

  let abandon_observer observer =
    let open Eta.Syntax in
    let* initial_batch =
      Execution.run execution @@ fun _checkpoint ->
      abandon_observer_now observer;
      Ok ()
    in
    run_edge_plan []
    |> E.map_error (function
         | `Observer_error _ ->
             failwith "Eta_signal: observer registration cleanup failed"
         | #graph_error as error -> error)

  let registration_with_cleanup observer_ref operation =
    Eta.Spi.Expert.make ~leaf_name:"eta_signal.observer_registration"
    @@ fun context ->
    let exit =
      try Eta.Spi.Expert.eval context operation
      with exn -> Eta.Spi.Expert.exit_of_exn context exn
    in
    (match exit with
    | Eta.Exit.Ok _ -> ()
    | Eta.Exit.Error _ ->
        Option.iter abandon_observer_now !observer_ref;
        ignore (Eta.Spi.Expert.eval context (run_edge_plan [])));
    exit

  module Observer = struct
    type 'a t = 'a observer
    type observer_finish = [ `Disposed | `Invalid_scope ]

    let observe ?cutoff ?on_finish ?on_update signal =
      let open Eta.Syntax in
      let* runtime = current_runtime () in
      let signal_timers = signal_timers signal in
      let mismatched_timer =
        List.find_opt
          (fun (timer : timer) ->
            timer.demand > 0
            && not
                 (Eta.Runtime_contract.same_runtime runtime timer.runtime))
          !timers
      in
      let* () =
        match mismatched_timer with
        | Some timer ->
            ignore timer;
            runtime_mismatch_with_cleanup
        | None -> (
          match
            List.find_opt
              (fun (timer : timer) ->
                not
                  (Eta.Runtime_contract.same_runtime runtime timer.runtime))
              signal_timers
          with
        | Some timer ->
            if timer.demand = 0 then E.fail `Runtime_mismatch
            else runtime_mismatch_with_cleanup
        | None -> E.unit)
      in
      let observer_ref = ref None in
      registration_with_cleanup observer_ref
      (let* observer =
        Execution.run execution @@ fun _checkpoint ->
        let result =
          observe_with ?cutoff ?on_finish signal @@ fun delivery ->
          match on_update, Edges.current delivery with
        | None, Some update ->
            (Option.get !observer_ref).published <-
              Some
                (match update with
                | Edges.Initialized value | Edges.Changed (_, value) -> value);
            Edges.Success ()
        | None, None -> Edges.Success ()
        | Some callback, Some update ->
            let outcome =
              edge_outcome_effect (fun () ->
                let open Eta.Syntax in
                let* active =
                  Execution.run execution @@ fun _checkpoint ->
                  Ok ((Option.get !observer_ref).lifecycle = Active)
                in
                if not active then E.unit
                else
                  let* still_active =
                    Execution.run execution @@ fun _checkpoint ->
                    Ok ((Option.get !observer_ref).lifecycle = Active)
                  in
                  if not still_active then E.unit
                  else
                    let* () = callback (edge_update update) in
                    let* () =
                      Execution.run execution @@ fun _checkpoint -> Ok ()
                    in
                    let* () =
                      Execution.run execution @@ fun _checkpoint -> Ok ()
                    in
                    Execution.run execution @@ fun _checkpoint -> Ok ())
            in
            (match outcome with
            | Edges.Success () ->
                (Option.get !observer_ref).callback_pending <- false;
                (Option.get !observer_ref).published <-
                  Some
                    (match update with
                    | Edges.Initialized value
                    | Edges.Changed (_, value) -> value);
                ()
            | Edges.Failure _ -> ());
            outcome
          | Some _, None -> Edges.Success ()
        in
        (match result with
        | Ok observer -> observer_ref := Some observer
        | Error _ -> ());
        result
      in
      observer.has_callback <- Option.is_some on_update;
      let* () =
         run_edge_plan []
         |> E.map_error (function
              | `Observer_error _ ->
                  failwith
                    "Eta_signal: impossible typed observer-registration failure"
              | #graph_error as error -> error)
       in
      let* observer =
        Execution.run execution @@ fun _checkpoint ->
        if observer.lifecycle = Invalid then Error `Invalid_scope
        else Ok observer
      in
      let* () =
        Execution.run execution @@ fun _checkpoint ->
        if observer.lifecycle = Invalid then Error `Invalid_scope
        else Ok ()
      in
      let* () =
        Execution.run execution @@ fun _checkpoint ->
        if observer.lifecycle = Invalid then Error `Invalid_scope
        else Ok ()
      in
      if observer.lifecycle = Invalid then E.fail `Invalid_scope
      else
        E.uninterruptible
          (E.sync (fun () ->
             transfer_observer observer;
             observer)))

    let read observer =
      Execution.run execution @@ fun _checkpoint ->
      match observer.lifecycle, observer.current with
      | Disposed, _ -> Error `Disposed_observer
      | Invalid, _ -> Error `Invalid_scope
      | Active, Some value -> Ok value
      | Active, None ->
          if !stabilization_attempts > observer.observed_attempt then
            Error `No_current_value
          else Error `Uninitialized_observer

    let dispose observer =
      let open Eta.Syntax in
      let* runtime = current_runtime () in
      let runtime_matches =
        List.for_all
          (fun (timer : timer) ->
            Eta.Runtime_contract.same_runtime runtime timer.runtime)
          observer.timer_demands
      in
      let* () =
        Execution.run execution @@ fun _checkpoint ->
        match observer.lifecycle with
        | Disposed -> Ok ()
        | Invalid ->
            observer.lifecycle <- Disposed;
            observers :=
              List.filter
                (fun (O candidate) -> candidate.id <> observer.id)
                !observers;
            pending_observers :=
              List.filter
                (fun (O candidate) -> candidate.id <> observer.id)
                !pending_observers;
            Edges.dispose edges observer.edge;
            Ok ()
        | Active ->
            let necessary_before = necessary_count () in
            observer.lifecycle <- Disposed;
            observers :=
              List.filter
                (fun (O candidate) -> candidate.id <> observer.id)
                !observers;
            pending_observers :=
              List.filter
                (fun (O candidate) -> candidate.id <> observer.id)
                !pending_observers;
            Core.release observer.demand;
            Option.iter Core.release observer.scope_demand;
            unlink_unnecessary_queued ();
            List.iter
              (fun (timer : timer) ->
                timer.demand <- max 0 (timer.demand - 1);
                if timer.demand = 0 then (
                  timer.start_pending <- false;
                  Edges.set_timer_demand edges timer.edge_timer false))
              observer.timer_demands;
            Edges.dispose edges observer.edge;
            nodes_became_unnecessary :=
              !nodes_became_unnecessary
              + max 0 (necessary_before - necessary_count ());
            Ok ()
      in
      if not runtime_matches then E.fail `Runtime_mismatch
      else if !sampling_timer_starts then E.unit
      else
        run_edge_plan []
        |> E.map_error (function
             | `Observer_error _ ->
                 failwith "Eta_signal: impossible typed disposal hook failure"
             | #graph_error as error -> error)
  end

  module For_stream = struct
    type nonrec 'a signal = 'a signal
    type nonrec 'a observer = 'a observer
    type nonrec 'a update = 'a update
    type nonrec 'a delivery = 'a delivery
    type nonrec observer_error = observer_error
    type observer_finish = [ `Disposed | `Invalid_scope ]

    let observe_delivery ?cutoff ?on_finish signal callback =
      let open Eta.Syntax in
      let* runtime = current_runtime () in
      let signal_timers = signal_timers signal in
      let mismatched_timer =
        List.find_opt
          (fun (timer : timer) ->
            timer.demand > 0
            && not
                 (Eta.Runtime_contract.same_runtime runtime timer.runtime))
          !timers
      in
      let* () =
        match mismatched_timer with
        | Some _ ->
            runtime_mismatch_with_cleanup
        | None -> (
        match
          List.find_opt
            (fun (timer : timer) ->
              not
                (Eta.Runtime_contract.same_runtime runtime timer.runtime))
            signal_timers
        with
        | Some timer ->
            if timer.demand = 0 then E.fail `Runtime_mismatch
            else runtime_mismatch_with_cleanup
        | None -> E.unit)
      in
      let observer_ref = ref None in
      registration_with_cleanup observer_ref
      (let* observer =
        Execution.run execution @@ fun _checkpoint ->
        let result =
          observe_with ?cutoff ?on_finish signal
            (fun delivery ->
              edge_outcome_effect (fun () ->
                let open Eta.Syntax in
                let* () =
                  Execution.run execution @@ fun _checkpoint -> Ok ()
                in
                callback delivery))
        in
        (match result with
        | Ok observer -> observer_ref := Some observer
        | Error _ -> ());
        result
      in
      observer.has_callback <- true;
      let* () =
         run_edge_plan []
         |> E.map_error (function
              | `Observer_error _ ->
                  failwith
                    "Eta_signal: impossible typed stream-registration failure"
              | #graph_error as error -> error)
       in
       let* observer =
         Execution.run execution @@ fun _checkpoint ->
         if observer.lifecycle = Invalid then Error `Invalid_scope
         else Ok observer
       in
       let* () =
         Execution.run execution @@ fun _checkpoint ->
         if observer.lifecycle = Invalid then Error `Invalid_scope
         else Ok ()
       in
       let* () =
         Execution.run execution @@ fun _checkpoint ->
         if observer.lifecycle = Invalid then Error `Invalid_scope
         else Ok ()
       in
       if observer.lifecycle = Invalid then E.fail `Invalid_scope
       else
         E.uninterruptible
           (E.sync (fun () ->
              transfer_observer observer;
              observer)))

    let current delivery =
      Execution.run execution @@ fun _checkpoint ->
      Ok (Option.map edge_update (Edges.current delivery))

    let acknowledge delivery =
      Execution.run execution @@ fun checkpoint ->
      checkpoint ();
      ignore (Edges.acknowledge delivery : bool);
      Ok ()

    let dispose = Observer.dispose
  end

  type 'a family_plan = Plan : {
    input : 'data_map signal;
    input_ops : ('key, 'data, 'data_map) package_input_ops;
    output_ops : ('key, 'output, 'output_map) package_output_ops;
    data_cutoff : 'data Cutoff.t;
    build : key:'key -> data:'data signal -> 'output signal;
  } -> 'output_map family_plan

  and ('key, 'data, 'map) package_input_ops = {
    p_empty : 'map;
    p_compare_key : 'key -> 'key -> int;
    p_fold :
      'acc. 'map -> 'map -> on_compare:(unit -> unit) -> init:'acc ->
      f:('acc -> 'key -> 'data package_change -> 'acc) -> 'acc;
  }
  and 'a package_change = PLeft of 'a | PRight of 'a | PChanged of 'a * 'a
  and ('key, 'output, 'map) package_output_ops = {
    p_output_empty : 'map;
    p_set : 'key -> 'output -> 'map -> 'map;
    p_remove : 'key -> 'map -> 'map;
  }

  module Package = struct
    type nonrec 'a signal = 'a signal
    type 'a plan = 'a family_plan
    type 'a change = Left of 'a | Right of 'a | Changed of 'a * 'a
    type ('key, 'data, 'map) input_ops = {
      empty : 'map;
      compare_key : 'key -> 'key -> int;
      fold_symmetric_diff :
        'acc. 'map -> 'map -> on_compare:(unit -> unit) -> init:'acc ->
        f:('acc -> 'key -> 'data change -> 'acc) -> 'acc;
    }
    type ('key, 'output, 'map) output_ops = {
      empty : 'map;
      set : 'key -> 'output -> 'map -> 'map;
      remove : 'key -> 'map -> 'map;
    }

    let stable_family ?data_cutoff ~input ~input_ops ~output_ops ~build () =
      let p_fold left right ~on_compare ~init ~f =
        input_ops.fold_symmetric_diff left right ~on_compare ~init
          ~f:(fun acc key change ->
            f acc key
              (match change with
              | Left value -> PLeft value
              | Right value -> PRight value
              | Changed (left, right) -> PChanged (left, right)))
      in
      Plan
        {
          input;
          input_ops =
            {
              p_empty = input_ops.empty;
              p_compare_key = input_ops.compare_key;
              p_fold;
            };
          output_ops =
            {
              p_output_empty = output_ops.empty;
              p_set = output_ops.set;
              p_remove = output_ops.remove;
            };
          data_cutoff = cutoff_or_default data_cutoff;
          build;
        }

    let install (type output_map) (Plan plan : output_map plan) =
      Execution.sync execution @@ fun () ->
      let input_ops : (_, _, _ option) Core.input_ops =
        {
          empty_input = None;
          compare_key = plan.input_ops.p_compare_key;
          iter_diff =
            (fun old next emit ->
              match old, next with
              | None, None -> ()
              | Some old, Some next ->
                  ignore
                    (plan.input_ops.p_fold old next
                       ~on_compare:(fun () ->
                         let s = !keyed in
                         keyed :=
                           { s with input_key_comparison_count =
                                      s.input_key_comparison_count + 1 })
                       ~init:()
                       ~f:(fun () key change ->
                         let s = !keyed in
                         keyed :=
                           { s with input_diff_event_count =
                                      s.input_diff_event_count + 1 };
                         match change with
                         | PLeft value -> emit key (Core.Left (Some value))
                         | PRight value -> emit key (Core.Right (Some value))
                         | PChanged (left, right) ->
                             if not (suppress plan.data_cutoff left right) then
                               emit key
                                 (Core.Changed (Some left, Some right))))
              | None, Some next ->
                  ignore
                    (plan.input_ops.p_fold plan.input_ops.p_empty next
                       ~on_compare:(fun () -> ())
                       ~init:()
                       ~f:(fun () key change ->
                         match change with
                         | PRight value -> emit key (Core.Right (Some value))
                         | PLeft _ | PChanged _ -> ()))
              | Some old, None ->
                  ignore
                    (plan.input_ops.p_fold old plan.input_ops.p_empty
                       ~on_compare:(fun () -> ())
                       ~init:()
                       ~f:(fun () key change ->
                         match change with
                         | PLeft value -> emit key (Core.Left (Some value))
                         | PRight _ | PChanged _ -> ())));
        }
      in
      let output_ops : (_, _ option, _ option) Core.output_ops =
        {
          empty_output = Some plan.output_ops.p_output_empty;
          set_output =
            (fun key value output ->
              match value with
              | None -> output
              | Some value ->
                  Some
                    (plan.output_ops.p_set key value
                       (Option.value output
                          ~default:plan.output_ops.p_output_empty)));
          remove_output =
            (fun key output ->
              Option.map (plan.output_ops.p_remove key) output);
        }
      in
      let owner_ref = ref None in
      let owner =
        Core.keyed_owner ~input:plan.input.raw ~input_ops ~output_ops
          ~build:(fun ~key ~data ->
            let signal = { raw = data; timer = None } in
            let output = plan.build ~key ~data:signal in
            let wrapped =
              map (fun value ->
                let s = !keyed in
                keyed :=
                  { s with child_visit_count = s.child_visit_count + 1 };
                Option.iter
                  (fun owner ->
                    owner.Core.keyed_signal.node.queued_in <- -1)
                  !owner_ref;
                value)
                output
            in
            Core.activate (Core.P wrapped.raw.node);
            List.iter (fun initialize -> initialize ()) !initializers;
            wrapped.raw)
          ()
      in
      owner_ref := Some owner;
      initializers :=
        (fun () ->
          if
            Core.validate_handle owner.Core.keyed_signal
            && owner.Core.keyed_signal.node.necessary
            && Core.value owner.Core.keyed_signal = None
          then Core.enqueue owner.Core.keyed_signal.packed)
        :: !initializers;
      let s = !keyed in
      keyed := { s with node_count = s.node_count + 1 };
      { raw = owner.Core.keyed_signal; timer = plan.input.timer }
  end

  let post_commit plan =
    Eta.Spi.Expert.make ~leaf_name:"eta_signal.post_commit" @@ fun context ->
    let contract = Eta.Spi.Expert.contract context in
    let previous_context = !edge_context in
    let previous_contract = edge_execution.Edge_execution.contract in
    edge_context := Some context;
    edge_execution.Edge_execution.contract <- Some contract;
    let previous_delivering = !delivering in
    let previous_delivering_fiber = !delivering_fiber in
    delivering := true;
    delivering_fiber := Some (contract.Eta.Runtime_contract.current_fiber_id ());
    let finish () =
      delivering := previous_delivering;
      delivering_fiber := previous_delivering_fiber;
      edge_execution.Edge_execution.contract <- previous_contract;
      edge_context := previous_context
    in
    Fun.protect ~finally:finish @@ fun () ->
    let failure = function
      | Edges.Typed_failure error ->
          Eta.Exit.Error (Eta.Cause.Fail (`Observer_error error))
      | Edges.Defect exn -> Eta.Spi.Expert.exit_of_exn context exn
      | Edges.Interrupted exn -> raise exn
    in
    let finalizer_failure failures =
      let diagnostic = function
        | Edges.Typed_failure error ->
            Eta.Cause.Finalizer.Fail
              {
                error;
                rendered = Format.asprintf "%a" Observer_error.pp error;
              }
        | Edges.Defect exn | Edges.Interrupted exn ->
            (match Eta.Spi.Expert.exit_of_exn context exn with
            | Eta.Exit.Error cause ->
                Eta.Cause.finalizer_of_cause Observer_error.pp cause
            | Eta.Exit.Ok _ -> assert false)
      in
      let diagnostics = List.map diagnostic failures in
      let finalizer =
        match diagnostics with
        | [ failure ] -> failure
        | _ -> Eta.Cause.Finalizer.Sequential diagnostics
      in
      Eta.Exit.Error (Eta.Cause.Finalizer finalizer)
    in
    edge_graph_error := None;
    let finishes = List.rev !pending_finishes in
    pending_finishes := [];
    List.iter (fun finish -> ignore (finish ())) finishes;
    let had_callback_delivery =
      List.exists
        (fun (O observer) ->
          observer.has_callback && observer.callback_pending)
        !observers
    in
    ignore (prepare_timer_starts_now contract);
    edge_start_failed := false;
    let result = Edges.run edges ~runtime:contract ~plan in
    (match result with
    | Ok () -> ()
    | Error _ ->
        ignore
          (Edges.drain_cleanup edges :
            (unit, observer_error Edges.run_error) result));
    match !edge_graph_error, result with
    | Some error, _ ->
        Eta.Exit.Error (Eta.Cause.Fail (error :> stabilize_error))
    | None, Ok () ->
        if had_callback_delivery then incr callback_delivery_count;
        Eta.Exit.Ok ()
    | None, Error Edges.Runtime_mismatch ->
        Eta.Exit.Error
          (Eta.Cause.Fail (`Runtime_mismatch :> stabilize_error))
    | None, Error (Edges.Callback_failure error) -> failure error
    | None, Error (Edges.Cleanup_failures (error :: _))
      when !edge_start_failed -> failure error
    | None, Error (Edges.Cleanup_failures errors) -> finalizer_failure errors

  let drain_edge_cleanup () =
    Eta.Spi.Expert.make ~leaf_name:"eta_signal.edge_cleanup" @@ fun context ->
    let contract = Eta.Spi.Expert.contract context in
    let previous_context = !edge_context in
    let previous_contract = edge_execution.Edge_execution.contract in
    edge_context := Some context;
    edge_execution.Edge_execution.contract <- Some contract;
    Fun.protect
      ~finally:(fun () ->
        edge_execution.Edge_execution.contract <- previous_contract;
        edge_context := previous_context)
      (fun () ->
        let disposals = List.rev !pending_edge_disposals in
        pending_edge_disposals := [];
        List.iter (fun dispose -> dispose ()) disposals;
        let finishes = List.rev !pending_finishes in
        pending_finishes := [];
        List.iter (fun finish -> ignore (finish ())) finishes;
        ignore
          (Edges.drain_cleanup edges :
            (unit, observer_error Edges.run_error) result);
        Eta.Exit.Ok ())

  let enqueue_uninitialized_necessary () =
    List.iter (fun enqueue -> enqueue ()) !initializers

  let enqueue_all_uninitialized_necessary () =
    for slot = 0 to graph.slot_count - 1 do
      match Core.slot_contents graph.slots.(slot) with
      | Some (Core.P node as packed)
        when node.necessary
             && Array.length node.dependencies > 0
             &&
             Option.is_none
               (Obj.magic node.current : Obj.t option) ->
          Core.enqueue packed
      | Some _ | None -> ()
    done

  let stabilize =
    let open Eta.Syntax in
    let* runtime =
      current_runtime ()
      |> E.map_error (fun error -> (error : stabilize_error))
    in
    let* initial_batch =
      (Execution.run execution @@ fun checkpoint ->
       let observed_timers =
         List.concat_map
           (fun (O observer) ->
             if observer.lifecycle = Active then
               signal_timers observer.signal
             else [])
           !observers
       in
       if
         !delivering_fiber
         = Some (runtime.Eta.Runtime_contract.current_fiber_id ())
       then Error `Reentrant_stabilization
       else if
         List.exists
           (fun (timer : timer) ->
             not
                  (Eta.Runtime_contract.same_runtime runtime timer.runtime))
           observed_timers
       then Error `Runtime_mismatch
       else (
         enqueue_uninitialized_necessary ();
         let seen_timer_work = Hashtbl.create 16 in
         let rec unlink_timer_work (Core.P node as packed) =
           if not (Hashtbl.mem seen_timer_work node.handle.slot) then (
             Hashtbl.add seen_timer_work node.handle.slot ();
             unlink_queued_node packed;
             List.iter unlink_timer_work node.dependents)
         in
         List.iter
           (fun (timer : timer) -> unlink_timer_work timer.source_node)
           !timers;
         incr stabilization_attempts;
         match Core.stabilize ~checkpoint graph with
         | Error Core.Reentrant_stabilization ->
             List.iter (fun timer -> timer.rollback_refresh ()) !timers;
             Error `Reentrant_stabilization
         | Error (Core.Defect (Graph_error error)) ->
             List.iter (fun timer -> timer.rollback_refresh ()) !timers;
             Error error
         | Error (Core.Defect exn) ->
             List.iter (fun timer -> timer.rollback_refresh ()) !timers;
             raise exn
         | Ok result ->
             List.iter (fun timer -> timer.commit_refresh ()) !timers;
             ignore result;
             incr pure_snapshot_commit_count;
             account_recomputations ();
             settle_invalid_observers ();
             reconcile_timer_demands runtime;
             if
               not
                 (List.exists
                    (fun (timer : timer) ->
                      timer.start_pending && timer.demand > 0)
                    !timers)
             then initializers := [];
             Ok (collect_observers ())))
      |> E.map_error (fun (#graph_error as error) ->
             (error : stabilize_error))
    in
    let* refreshed =
      E.on_exit
        (function
          | Eta.Exit.Ok _ -> E.unit
          | Eta.Exit.Error _ -> drain_edge_cleanup ())
        (E.sync (fun () ->
           List.iter
             (fun (timer : timer) ->
               if timer.demand = 0 then timer.rollback_refresh ())
             !timers;
           prepare_timer_starts_now runtime))
    in
    let _started_refreshed, started = refreshed in
    let started_admitted =
      List.fold_left
        (fun admitted (timer : timer) ->
          (timer.demand > 0 && timer.admit_refresh ()) || admitted)
        false started
    in
    let* active_refreshed =
      E.sync (fun () ->
        let active =
          List.fold_left
            (fun active (O observer) ->
              if observer.lifecycle <> Active then active
              else
                List.fold_left
                  (fun active timer ->
                    if
                      List.exists (( == ) timer) started
                      || List.exists (( == ) timer) active
                    then active
                    else timer :: active)
                  active (signal_timers observer.signal))
            [] !observers
        in
        match active with
        | [] -> false
        | timers ->
            let now = runtime.Eta.Runtime_contract.now_ms () in
            List.iter (fun timer -> timer.refresh runtime now) timers;
            ignore
              (List.fold_left
                 (fun admitted timer ->
                   timer.admit_refresh () || admitted)
                 false timers);
            true)
    in
    let refreshed =
      started <> [] || started_admitted || active_refreshed
    in
    let* batch =
      (Execution.run execution @@ fun checkpoint ->
       let stale_bind = ref false in
       Hashtbl.iter
         (fun slot handle ->
           match Core.slot_contents graph.slots.(slot) with
           | Some (Core.P node as packed)
             when node.handle = handle
                  && node.necessary
                  && Array.length node.dependencies > 1 ->
               let Core.P inner =
                 node.dependencies.(Array.length node.dependencies - 1)
               in
               if Obj.repr node.current != Obj.repr inner.current then (
                 Core.enqueue packed;
                 stale_bind := true)
           | Some _ | None -> ())
         bind_nodes;
       let stale_duplicate = ref false in
       let committed_pass = graph.pass - 1 in
       let seen_descendants = Hashtbl.create 16 in
       let rec enqueue_descendants (Core.P node as packed) =
         if not (Hashtbl.mem seen_descendants node.handle.slot) then (
           Hashtbl.add seen_descendants node.handle.slot ();
           if node.necessary then Core.enqueue packed;
           List.iter enqueue_descendants node.dependents)
       in
       for slot = 0 to graph.slot_count - 1 do
         match Core.slot_contents graph.slots.(slot) with
         | Some (Core.P node) when node.necessary ->
             let duplicate = ref false in
             for left = 0 to Array.length node.dependencies - 1 do
               for right = left + 1 to Array.length node.dependencies - 1 do
                 let Core.P left_node = node.dependencies.(left) in
                 let Core.P right_node = node.dependencies.(right) in
                 if left_node.handle = right_node.handle then duplicate := true
               done
             done;
             let dependency_changed =
               Array.exists
                 (fun (Core.P dependency) ->
                   dependency.written_in = committed_pass)
                 node.dependencies
             in
             let custom_dependency =
               Array.exists
                 (fun (Core.P dependency) ->
                   Hashtbl.find_opt custom_cutoff_nodes dependency.handle.slot
                   = Some dependency.handle)
                 node.dependencies
             in
             if !duplicate && dependency_changed && not custom_dependency then (
               Core.enqueue (Core.P node);
               List.iter enqueue_descendants node.dependents;
               stale_duplicate := true)
         | Some _ | None -> ()
       done;
       if refreshed || !stale_bind || !stale_duplicate then
         (enqueue_uninitialized_necessary ();
         enqueue_all_uninitialized_necessary ();
         match Core.stabilize ~checkpoint graph with
         | Error Core.Reentrant_stabilization ->
             List.iter (fun timer -> timer.rollback_refresh ()) !timers;
             Error `Reentrant_stabilization
         | Error (Core.Defect (Graph_error error)) ->
             List.iter (fun timer -> timer.rollback_refresh ()) !timers;
             Error error
         | Error (Core.Defect exn) ->
             List.iter (fun timer -> timer.rollback_refresh ()) !timers;
             raise exn
         | Ok result ->
             List.iter (fun timer -> timer.commit_refresh ()) !timers;
             ignore result;
             initializers := [];
             account_recomputations ();
             settle_invalid_observers ();
             reconcile_timer_demands runtime;
             Ok (collect_observers ()))
       else Ok initial_batch)
      |> E.map_error (fun (#graph_error as error) ->
             (error : stabilize_error))
    in
    post_commit batch

  let pp_observer_read_error ppf = function
    | `Disposed_observer -> Format.pp_print_string ppf "disposed observer"
    | `Invalid_scope -> Format.pp_print_string ppf "invalid dynamic scope"
    | `No_current_value ->
        Format.pp_print_string ppf "no current observer value"
    | `Uninitialized_observer ->
        Format.pp_print_string ppf "uninitialized observer"
  let pp_stabilize_error ppf = function
    | `Observer_error error ->
        Format.fprintf ppf "observer callback failed: %a" Observer_error.pp error
    | #graph_error as error -> pp_graph_error ppf error
  let pp_time_error ppf = function
    | `Deadline_overflow ->
        Format.pp_print_string ppf "deadline arithmetic overflow"
    | `Invalid_interval -> Format.pp_print_string ppf "invalid interval"
    | `Past_deadline -> Format.pp_print_string ppf "deadline is in the past"
    | #graph_error as error -> pp_graph_error ppf error

  let stats () =
    Execution.run execution @@ fun _checkpoint ->
    if graph.phase = Core.Idle then Core.release_unreachable_roots graph;
    let total = ref 0 and necessary = ref 0 and dirty = ref 0 in
    for slot = 0 to graph.slot_count - 1 do
      match Core.slot_contents graph.slots.(slot) with
      | None -> ()
      | Some (Core.P node) ->
          let internal_source =
            not node.constant && Array.length node.dependencies = 0
          in
          if not internal_source then incr total;
          if node.necessary && not internal_source then incr necessary;
          if node.admitted then incr dirty
    done;
    let active = ref 0 and invalid = ref 0 in
    List.iter
      (fun (O observer) ->
        match observer.lifecycle with
        | Active -> incr active
        | Invalid -> incr invalid
        | Disposed -> ())
      !observers;
    List.iter
      (fun (O observer) ->
        match observer.lifecycle with
        | Active -> incr active
        | Invalid -> incr invalid
        | Disposed -> ())
      !pending_observers;
    Ok
      {
        pure_snapshot_commit_count = !pure_snapshot_commit_count;
        callback_delivery_count = !callback_delivery_count;
        total_node_count = !total;
        active_observer_count = !active;
        invalid_observer_count = !invalid;
        necessary_node_count = !necessary;
        dead_node_count = !dead_nodes;
        live_dirty_node_count = !dirty;
        recompute_count = !recompute_count;
        dynamic_scope_invalidations = !dynamic_scope_invalidations;
        nodes_became_necessary = !nodes_became_necessary;
        nodes_became_unnecessary = !nodes_became_unnecessary;
        lane_waiter_count = Lane.waiting_count execution.lane;
        lane_cancelled_waiter_count = Lane.cancelled_count execution.lane;
        keyed = !keyed;
      }

  let to_dot ?(options = default_dot_options) () =
    Execution.run execution @@ fun _checkpoint ->
    Core.release_unreachable_roots graph;
    let buffer = Buffer.create 256 in
    Buffer.add_string buffer "digraph eta_signal {\n";
    for slot = 0 to graph.slot_count - 1 do
      match Core.slot_contents graph.slots.(slot) with
      | None -> ()
      | Some (Core.P node) ->
          let internal_source =
            not node.constant && Array.length node.dependencies = 0
          in
          if
            not internal_source
            && (options.dot_scope <> `Necessary || node.necessary)
          then (
            let dependent_count = ref 0 in
            for candidate_slot = 0 to graph.slot_count - 1 do
              match Core.slot_contents graph.slots.(candidate_slot) with
              | Some (Core.P candidate) ->
                  Array.iter
                    (fun (Core.P dependency) ->
                      if dependency.handle = node.handle then
                        incr dependent_count)
                    candidate.dependencies
              | None -> ()
            done;
            Buffer.add_string buffer
              (Printf.sprintf "  signal_%d [label=\"signal_%d%s\"];\n"
                 slot slot
                  (if options.dot_state then
                    Printf.sprintf
                      " necessary=%b dirty=%b queued=%b dependencies=%d dependents=%d signal_id=s%d%s"
                      node.necessary
                      (node.admitted
                      || Array.exists
                           (fun (Core.P dependency) -> dependency.admitted)
                           node.dependencies)
                      (node.queued_in = graph.pass
                      || Array.exists
                           (fun (Core.P dependency) ->
                             dependency.admitted
                             || dependency.queued_in = graph.pass)
                           node.dependencies)
                      (Array.length node.dependencies) !dependent_count slot
                      (match node.scope with
                      | None -> ""
                      | Some scope ->
                          Printf.sprintf
                            " scope=%s scope_id=sc%d scope_owner=s%d scope_parent=root"
                            (if scope.valid then "valid" else "invalid")
                            scope.slot_head scope.slot_head)
                  else ""));
            Array.iter
              (fun (Core.P child) ->
                let child_internal =
                  not child.constant
                  && Array.length child.dependencies = 0
                in
                if not child_internal then
                  Buffer.add_string buffer
                    (Printf.sprintf "  signal_%d -> signal_%d;\n"
                       child.handle.slot slot))
              node.dependencies)
    done;
    if options.dot_dynamic_scopes && !scope_owners <> [] then
      Buffer.add_string buffer
        "  dynamic_scopes [label=\"scope=valid scope_id=sc0 scope_owner=s0 scope_parent=root\"];\n";
    if options.dot_scope = `All_including_invalid then
      for dead = 1 to !dead_nodes do
        Buffer.add_string buffer
          (Printf.sprintf
             "  dead_s%d [label=\"dead_s%d valid=false scope=:invalid\"];\n"
             dead dead)
      done;
    if options.dot_observers then
      List.iter
        (fun (O observer) ->
          if observer.lifecycle <> Disposed then (
            Buffer.add_string buffer
              (Printf.sprintf
                 "  observer_%d [label=\"observer:%d state=%s value_state=%s%s\"];\n"
                 observer.id observer.id
                 (match observer.lifecycle with
                 | Active -> "active"
                 | Invalid -> "invalid_scope"
                 | Disposed -> "disposed")
                 (if Option.is_some observer.current then "current"
                  else "uninitialized")
                 (if
                    observer.lifecycle = Invalid
                    && not (Core.validate_handle observer.signal.raw)
                  then " missing_observed_signal_id=s"
                  else ""));
            Buffer.add_string buffer
              (Printf.sprintf
                 "  observer_%d -> signal_%d [style=dashed,label=\"observes\"];\n"
                 observer.id observer.signal.raw.handle.slot)))
        !observers;
    if options.dot_timers then
      List.iteri
        (fun index (timer : timer) ->
          Buffer.add_string buffer
            (Printf.sprintf
               "  timer_%d [label=\"timer_active=%b timer_state=%s var_id=v%d\"];\n"
               index (timer.demand > 0)
               (if timer.demand > 0 then "running" else "inactive")
               index))
        !timers;
    Buffer.add_string buffer "}\n";
    Ok (Buffer.contents buffer)

  module Time = struct
    exception Timer_cancelled
    exception Timer_start_abandoned

    type monotonic_time = {
      runtime : Eta.Runtime_contract.t;
      milliseconds : int;
    }

    let to_ms time = time.milliseconds

    let add time duration =
      let delta = Eta.Duration.to_ms duration in
      if delta <= 0 then Error `Past_deadline
      else if time.milliseconds > max_int - delta then Error `Deadline_overflow
      else Ok { time with milliseconds = time.milliseconds + delta }

    let validate duration =
      if Eta.Duration.to_ms duration <= 0 then Error `Invalid_interval else Ok ()

    let make_timer ?last_sample runtime kind initial refresh_value =
      let force_source = ref false in
      let source =
        {
          source =
            Core.var
              ~cutoff:(fun old next ->
                match kind with
                | Ticks _ -> false
                | Every _ | At _ | No_timer ->
                    (not !force_source) && old == next)
              graph (Some initial);
          value = initial;
          cutoff = Cutoff.never;
          updating = false;
        }
      in
      let edge_timer_ref = ref None in
      let admit_ref = ref (fun (_ : Eta.Runtime_contract.t) -> ()) in
      let begin_refresh = ref (fun () -> ()) in
      let rollback_refresh = ref (fun () -> ()) in
      let commit_refresh = ref (fun () -> ()) in
      let startup_cleanup :
          (int * (unit -> (unit, observer_error) Edges.outcome)) option ref =
        ref None
      in
      let sleep_duration runtime =
        match kind with
        | Every interval | Ticks interval -> Eta.Duration.ms interval
        | At deadline ->
            Eta.Duration.ms
              (max 1 (deadline - runtime.Eta.Runtime_contract.now_ms ()))
        | No_timer -> Eta.Duration.ms 1
      in
      let policy =
        Edges.
          {
            same_runtime = Eta.Runtime_contract.same_runtime;
            start =
              (fun runtime ~generation ->
                try
                  (match !edge_timer_ref with
                  | Some edge_timer
                    when Edges.timer_generation edge_timer = generation ->
                      ()
                  | Some _ | None ->
                      raise Timer_start_abandoned);
                  let cancel_ref = ref None in
                  let stop_requested = ref false in
                  let stop () =
                    stop_requested := true;
                    match !cancel_ref with
                    | None -> Edges.Success ()
                    | Some cancel ->
                        (try
                           cancel ();
                           Edges.Success ()
                         with exn -> Edges.Failure (Edges.Defect exn))
                  in
                  startup_cleanup := Some (generation, stop);
                  let daemon =
                  Eta.Spi.Expert.make ~leaf_name:"eta_signal.timer" @@ fun context ->
                  let contract = Eta.Spi.Expert.contract context in
                  Fun.protect
                    ~finally:(fun () -> cancel_ref := None)
                    (fun () ->
                  try
                    contract.Eta.Runtime_contract.cancel_sub @@ fun cancel_context ->
                    let cancel () =
                      contract.Eta.Runtime_contract.cancel cancel_context
                        Timer_cancelled
                    in
                    cancel_ref := Some cancel;
                    if !stop_requested then cancel ()
                    else (
                      let rec loop () =
                        contract.Eta.Runtime_contract.sleep
                          (sleep_duration contract);
                        let previous =
                          edge_execution.Edge_execution.contract
                        in
                        edge_execution.Edge_execution.contract <-
                          Some contract;
                        let accepted =
                          Fun.protect
                            ~finally:(fun () ->
                              edge_execution.Edge_execution.contract <-
                                previous)
                            (fun () ->
                              match !edge_timer_ref with
                              | None -> false
                              | Some edge_timer ->
                                  (match
                                     Edges.timer_wake_with edges
                                       ~runtime:contract edge_timer ~generation
                                       ~admit:(fun () -> !admit_ref contract)
                                   with
                                  | Ok accepted -> accepted
                                  | Error _ -> false))
                        in
                        if accepted then
                          match kind with
                          | At _ -> ()
                          | Every _ | Ticks _ | No_timer -> loop ()
                        else if
                          not !stop_requested
                          &&
                          match !edge_timer_ref with
                          | Some edge_timer ->
                              Edges.timer_generation edge_timer = generation
                          | None -> false
                        then (
                          match kind with
                          | Ticks _ ->
                              !admit_ref contract;
                              loop ()
                          | At _ | Every _ | No_timer -> ())
                      in
                      loop ());
                    Eta.Exit.Ok ()
                  with exn ->
                    if
                      Option.is_some
                        (contract.Eta.Runtime_contract.cancellation_reason exn)
                    then Eta.Exit.Ok ()
                    else Eta.Spi.Expert.exit_of_exn context exn)
                in
                let operation =
                  let open Eta.Syntax in
                  let* () = Eta.Spi.daemon daemon in
                  E.sync (fun () -> stop)
                in
                  match edge_outcome operation with
                  | Edges.Success cancel ->
                      startup_cleanup := None;
                      Edges.Success cancel
                  | Edges.Failure failure ->
                      edge_start_failed := true;
                      Edges.Failure failure
                with
                | Timer_start_abandoned ->
                    Edges.Success (fun () -> Edges.Success ())
                | exn ->
                    edge_start_failed := true;
                    Edges.Failure (Edges.Defect exn));
          }
      in
      let edge_timer =
        Edges.create_timer_with_cleanup edges ~runtime ~policy
          ~on_start_failure:(fun ~generation _ ->
            match !startup_cleanup with
            | Some (active, cleanup) when active = generation ->
                startup_cleanup := None;
                cleanup ()
            | Some _ | None -> Edges.Success ())
      in
      edge_timer_ref := Some edge_timer;
      let last_sample =
        match last_sample with
        | Some sample -> sample
        | None -> runtime.Eta.Runtime_contract.now_ms ()
      in
      let sample = ref last_sample in
      let candidate = ref None in
      let speculative = ref None in
      begin_refresh :=
        (fun () ->
          if Option.is_none !speculative then
            speculative := Some (!sample, source.value));
      rollback_refresh :=
        (fun () ->
          match !speculative with
          | None -> ()
          | Some (previous_sample, previous_value) ->
              speculative := None;
              candidate := None;
              force_source := false;
              sample := previous_sample;
              source.value <- previous_value;
              source.source.accepted := Some previous_value;
              let node = source.source.signal.node in
              let retained = ref 0 in
              for index = 0 to graph.admission_length - 1 do
                let slot = graph.admissions.(index) in
                if slot <> node.handle.slot then (
                  graph.admissions.(!retained) <- slot;
                  incr retained)
              done;
              graph.admission_length <- !retained;
              node.admitted <- false;
              unlink_queued_node source.source.signal.packed);
      commit_refresh :=
        (fun () ->
          speculative := None;
          force_source := false);
      let reset active_runtime =
        if not (Eta.Runtime_contract.same_runtime active_runtime runtime) then
          raise (Graph_error `Runtime_mismatch);
        !begin_refresh ();
        let now = active_runtime.Eta.Runtime_contract.now_ms () in
        sample := now;
        now
      in
      let refresh active_runtime now =
        if not (Eta.Runtime_contract.same_runtime active_runtime runtime) then
          raise (Graph_error `Runtime_mismatch);
        let current = Option.value !candidate ~default:source.value in
        match refresh_value current now !sample with
        | None -> ()
        | Some (value, next_sample) ->
            !begin_refresh ();
            sample := next_sample;
            candidate := Some value
      in
      let admit_refresh () =
        match !candidate with
        | None -> false
        | Some value ->
            candidate := None;
            force_source := true;
            source.value <- value;
            Core.set graph source.source (Some value);
            Core.enqueue source.source.signal.packed;
            true
      in
      admit_ref :=
        (fun active_runtime ->
          refresh active_runtime
            (active_runtime.Eta.Runtime_contract.now_ms ()));
      let timer =
        {
          runtime;
          kind;
          last_sample;
          demand = 0;
          start_pending = false;
          generation = 0;
          cancel = None;
          edge_timer;
          source_node = source.source.signal.packed;
          reset;
          refresh;
          admit_refresh;
          commit_refresh = (fun () -> !commit_refresh ());
          rollback_refresh = (fun () -> !rollback_refresh ());
        }
      in
      timers := timer :: !timers;
      let watched = Var.watch source in
      timer_roots := watched.raw.packed :: !timer_roots;
      Hashtbl.replace timer_nodes watched.raw.handle.slot
        (watched.raw.handle, timer);
      ({ watched with timer = Some timer }, source)

    let now ~every =
      let open Eta.Syntax in
      match validate every with
      | Error error -> E.fail error
      | Ok () ->
          let* runtime = current_runtime () in
          Execution.run execution @@ fun _checkpoint ->
          let milliseconds = runtime.Eta.Runtime_contract.now_ms () in
          let signal, _ =
            make_timer ~last_sample:milliseconds runtime
              (Every (Eta.Duration.to_ms every))
              { runtime; milliseconds }
              (fun _ now _ ->
                Some ({ runtime; milliseconds = now }, now))
          in
          Ok signal

    let deadline time =
      let open Eta.Syntax in
      let* runtime = current_runtime () in
      if not (Eta.Runtime_contract.same_runtime runtime time.runtime) then
        E.fail `Runtime_mismatch
      else
        Execution.run execution @@ fun _checkpoint ->
        let now = runtime.Eta.Runtime_contract.now_ms () in
        if time.milliseconds <= now then Error `Past_deadline
        else
          let signal, _ =
            make_timer ~last_sample:now runtime (At time.milliseconds) false
              (fun _ now sample ->
                Some (now >= time.milliseconds, sample))
          in
          Ok signal

    let after duration =
      let open Eta.Syntax in
      let delta = Eta.Duration.to_ms duration in
      if delta <= 0 then E.fail `Past_deadline
      else
        let* runtime = current_runtime () in
        Execution.run execution @@ fun _checkpoint ->
        let now = runtime.Eta.Runtime_contract.now_ms () in
        if now > max_int - delta then Error `Deadline_overflow
        else
          let deadline = now + delta in
          let signal, _ =
            make_timer ~last_sample:now runtime (At deadline) false
              (fun _ now sample -> Some (now >= deadline, sample))
          in
          Ok signal

    let interval duration =
      let open Eta.Syntax in
      match validate duration with
      | Error error -> E.fail error
      | Ok () ->
          let* runtime = current_runtime () in
          let fiber = runtime.Eta.Runtime_contract.current_fiber_id () in
          let ambiguous =
            match execution.Execution.owner_fiber_id with
            | Some owner when owner <> fiber ->
                graph.phase <> Core.Idle || graph.running
            | Some _ | None -> false
          in
          Execution.run execution @@ fun _checkpoint ->
          if ambiguous then Error `Ambiguous_scope
          else
            let signal, _ =
              let period = Eta.Duration.to_ms duration in
              make_timer runtime (Ticks period) 0
                (fun value now sample ->
                  let elapsed =
                    Int64.sub (Int64.of_int now) (Int64.of_int sample)
                  in
                  let ticks64 =
                    if Int64.compare elapsed 0L <= 0 then 0L
                    else Int64.div elapsed (Int64.of_int period)
                  in
                  let ticks =
                    if Int64.compare ticks64 (Int64.of_int max_int) > 0
                    then max_int
                    else Int64.to_int ticks64
                  in
                  if ticks = 0 then None
                  else
                    Some
                      ( (if value > max_int - ticks then max_int
                         else value + ticks),
                        let next_sample =
                          Int64.add (Int64.of_int sample)
                            (Int64.mul ticks64 (Int64.of_int period))
                        in
                        if
                          Int64.compare next_sample
                            (Int64.of_int max_int)
                          > 0
                        then now
                        else Int64.to_int next_sample ))
            in
            Ok signal
  end
end

module Make (Observer_error : Observer_error) () :
  Result with type observer_error = Observer_error.t =
  Make_impl (Observer_error) ()

module Make_no_error () :
  Result with type observer_error = No_observer_error.t =
  Make (No_observer_error) ()

module Raw_benchmark = struct
  type workload = {
    name : string;
    run_batch : int -> unit;
    final_read_and_check : unit -> unit;
  }

  let make_scalar ?(cutoff = false) ~depth () =
    let raw = Core.raw_scalar ~cutoff depth in
    {
      name = raw.name;
      run_batch = raw.run_batch;
      final_read_and_check = raw.check;
    }
end
