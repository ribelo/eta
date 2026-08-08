(* Graph: owner-domain phase authority.

   Invariant: every graph operation runs on its creating domain in exactly
   one explicit phase; rollback authority exists only while planning.

   DAG: Propagation and Post_commit are independent leaves; this module
   composes both and owns the Eta effect seam. *)

module E = Eta.Effect
module Core = Propagation
module Edges = Post_commit

module type Observer_error = sig
  type t
  val pp : Format.formatter -> t -> unit
end

module No_observer_error = struct
  type t = |
  let pp _ (error : t) = match error with _ -> .
end

type graph_error = Error.graph_error

type observer_read_error = Error.observer_read_error

type time_error = Error.time_error

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

module type Result = sig
  type observer_error
  type nonrec graph_error = graph_error
  exception Graph_error of graph_error
  type nonrec observer_read_error = observer_read_error
  type stabilize_error = [ graph_error | `Observer_error of observer_error ]
  type nonrec time_error = time_error
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
    val set : 'a t -> 'a -> (unit, [> `Reentrant_update ]) result
    val update_effect :
      'a t -> ('a -> ('a, 'err) E.t) ->
      ('a, [> `Reentrant_update ] as 'err) E.t
  end
  module Observer : sig
    type 'a t = 'a observer
    type observer_finish = [ `Disposed | `Invalid_scope ]
    val observe :
      ?cutoff:'a Cutoff.t -> ?on_finish:(observer_finish -> unit) ->
      ?on_update:('a update -> (unit, observer_error) result) ->
      'a signal -> ('a t, graph_error) result
    val read : 'a t -> ('a, observer_read_error) result
    val dispose : 'a t -> (unit, graph_error) result
  end
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
  val stabilize : unit -> (unit, stabilize_error) result
  val stats : unit -> (stats, graph_error) result
  val to_dot : ?options:dot_options -> unit -> string
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
  type t = { owner_domain : Domain.id }

  let create () = { owner_domain = Domain.self () }

  let ensure_context t =
    if Domain.self () <> t.owner_domain
       || Eta.Runtime_contract.in_registered_worker_context ()
    then
      invalid_arg
        "Eta_signal: signal graph APIs must be called on the domain that created \
         the graph and not from runtime worker callbacks"

  let sync t f =
    ensure_context t;
    f ()
end

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
    now_ms : unit -> int;
    reset : int -> int;
    refresh : int -> unit;
    admit_refresh : unit -> bool;
    commit_refresh : unit -> unit;
    rollback_refresh : unit -> unit;
  }

  type 'a signal = {
    raw : 'a option Core.signal;
    timer : timer option;
  }

  let raw_for_testing signal = signal.raw

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
  let edges = Edges.create ()
  (* The single public-operation phase machine. [Planning] runs exactly
     while a propagation pass executes; [Delivering] runs exactly while
     post-commit delivery executes. *)
  let phase : [ `Idle | `Planning | `Delivering ] ref = ref `Idle
  let with_phase next f =
    let previous = !phase in
    phase := next;
    Fun.protect ~finally:(fun () -> phase := previous) f
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
  let duplicate_dependency_nodes : (int, Core.handle) Hashtbl.t =
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
  let enqueue_reactivated = Core.enqueue_reactivated
  let necessary_count () = Core.count_necessary graph
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
  let raw_value signal = signal.raw.node.current |> value_exn
  let check_signal signal =
    if not (Core.validate_handle signal.raw) then
      match signal.raw.node.scope with
      | Some _ -> raise (Graph_error `Invalid_scope)
      | None ->
          if
            not
              (Core.reinstall_freed graph signal.raw.handle signal.raw.packed)
          then raise (Graph_error `Invalid_scope)

  let make_raw ?cutoff:cutoff_arg ~height ~dependencies compute =
    if !phase <> `Idle && Core.current_scope graph = None then
      raise (Graph_error `Ambiguous_scope);
    let cutoff = cutoff_or_default cutoff_arg in
    let computed_in = ref (-1) in
    let computed = ref None in
    let duplicate_evaluation = ref false in
    let compute_once () =
      if !computed_in = Core.current_pass graph then (
        duplicate_evaluation := true;
        Option.get !computed)
      else
        let value = compute () in
        computed_in := Core.current_pass graph;
        computed := Some value;
        duplicate_evaluation := false;
        value
    in
    let inherited_scope =
      if Option.is_some (Core.current_scope graph) then None
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
        Option.is_some (Core.current_scope graph) || Option.is_some inherited_scope
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
    let duplicate = ref false in
    for left = 0 to Array.length dependencies - 1 do
      for right = left + 1 to Array.length dependencies - 1 do
        let Core.P left_node = dependencies.(left) in
        let Core.P right_node = dependencies.(right) in
        if left_node.handle = right_node.handle then duplicate := true
      done
    done;
    if !duplicate then (
      Core.enable_change_listeners graph;
      Hashtbl.replace duplicate_dependency_nodes raw.handle.slot raw.handle);
    if cutoff != Cutoff.phys_equal then
      Hashtbl.replace custom_cutoff_nodes raw.handle.slot raw.handle;
    let weak_raw = Weak.create 1 in
    Weak.set weak_raw 0 (Some raw.packed);
    let invalidate () =
      if !computed_in = Core.current_pass graph then (
        match Weak.get weak_raw 0 with
        | Some packed -> Core.clear_queue_mark packed
        | None -> ());
      computed_in := -1;
      duplicate_evaluation := false
    in
    Hashtbl.replace compute_invalidators raw.handle.slot invalidate;
    Array.iter
      (fun (Core.P dependency as packed_dependency) ->
        Core.move_dependent_last packed_dependency raw.node.handle;
        Core.prepend_change_listener packed_dependency (fun _ ->
            if !computed_in = Core.current_pass graph then invalidate ()))
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
    if !phase <> `Idle && Core.current_scope graph = None then
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
      if !phase = `Planning then raise (Graph_error `Ambiguous_scope);
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
      Execution.sync execution @@ fun () ->
      if var.updating then Error `Reentrant_update
      else (
        Core.set graph var.source (Some value);
        var.value <- value;
        Ok ())

    let update_effect (var : 'a t) f =
      let open Eta.Syntax in
      let operation =
        let* current =
          E.sync_result (fun () ->
            ensure_context ();
            if var.updating then Error `Reentrant_update
            else (
              var.updating <- true;
              Ok var.value))
        in
        f current
      in
      E.on_exit
        (function
          | Eta.Exit.Ok value ->
              E.sync (fun () ->
                ensure_context ();
                Core.set graph var.source (Some value);
                var.value <- value;
                var.updating <- false)
          | Eta.Exit.Error _ ->
              E.sync (fun () ->
                ensure_context ();
                var.updating <- false))
        operation
  end

  let unlink_queued_node = Core.unlink_queued_node

  let unlink_unnecessary_queued () = Core.unlink_unnecessary_queued graph

  let ensure_parent_height ?current packed minimum =
    Core.ensure_parent_height graph ?current packed minimum

  let bind ?cutoff ~f source =
    Execution.sync execution @@ fun () ->
    check_signal source;
    Core.enable_change_listeners graph;
    let selected = ref None in
    let inner = ref None in
    let scope = ref None in
    let owner = ref None in
    let evaluated_in = ref (-1) in
    let yielded_no_value_in = ref (-1) in
    let topology_nodes = Core.dependency_subgraph in
    let adjust_topology_priority = Core.adjust_topology_priority in
    let enqueue_uninitialized_topology = Core.enqueue_uninitialized_topology in
    let compute () =
      evaluated_in := Core.current_pass graph;
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
          | None -> Core.current_scope graph
        in
        let fresh_scope = Core.create_scope () in
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
        let validate_scope candidate =
            if
              not (Core.scope_valid candidate)
              || not
                   (candidate == fresh_scope
                    || scope_is_ancestor candidate parent_scope)
            then raise (Graph_error `Invalid_scope)
        in
        if Array.length fresh.raw.node.dependencies = 0 then
          Option.iter validate_scope fresh.raw.node.scope
        else
          List.iter validate_scope (Core.distinct_scopes fresh.raw.packed);
        let owner_handle = (Option.get !owner).raw.handle in
        if Core.reaches_handle fresh.raw.packed owner_handle then (
          let seen_pending = Hashtbl.create 8 in
          let rec has_pending_bind (Core.P node) =
            if Hashtbl.mem seen_pending node.handle.slot then false
            else (
              Hashtbl.add seen_pending node.handle.slot ();
              match Hashtbl.find_opt bind_evaluations node.handle.slot with
              | Some (handle, pass)
                when handle = node.handle
                     && !pass <> Core.current_pass graph
                     && node.in_queue ->
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
        if (Option.get !owner).raw.node.height <= fresh.raw.node.height then
          ensure_parent_height ~current:true packed_owner
            (fresh.raw.node.height + 1);
        Option.iter
          (fun invalidate ->
            Core.prepend_change_listener (Core.P fresh.raw.node) (fun _ ->
                invalidate ()))
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
              dead_nodes := !dead_nodes + Core.invalidate_scope_chain graph scope
            in
            retire old_scope)
          old_scope;
        (* Retired scopes are invalid and so is their whole subtree; keep the
           ancestry and owner indices bounded to live scopes. *)
        scope_parents :=
          List.filter (fun ((child : Core.scope), _) -> Core.scope_valid child)
            !scope_parents;
        scope_owners :=
          List.filter (fun ((scope : Core.scope), _) -> Core.scope_valid scope)
            !scope_owners;
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
          if !yielded_no_value_in <> Core.current_pass graph then (
            yielded_no_value_in := Core.current_pass graph;
            let inner = Option.get !inner in
            if !timers = [] || signal_timers inner = [] then (
              enqueue_uninitialized_topology inner.raw.packed;
              Core.clear_queue_mark owner.raw.packed;
              Core.enqueue_deferred owner.raw.packed));
          Core.value owner.raw)
      with Deferred_bind ->
        let owner = Option.get !owner in
        Core.clear_queue_mark owner.raw.packed;
        Core.enqueue_deferred owner.raw.packed;
        Option.bind !inner (fun signal -> Core.value signal.raw)
      | Deferred_source ->
        let owner = Option.get !owner in
        Core.clear_queue_mark owner.raw.packed;
        Option.bind !inner (fun signal -> Core.value signal.raw)
    in
    let selected_cutoff = cutoff_or_default cutoff in
    let raw =
      Core.make_node graph ~height:(source.raw.node.height + 2)
        ~dependencies:[| Core.P source.raw.node |] ~compute
        ~cutoff:(option_cutoff selected_cutoff) ~initial:None
    in
    raw.node.topology_priority <- 1;
    let selector_priority_active = ref false in
    let selector_priority_nodes = ref [] in
    raw.node.demand_listeners <-
      (fun necessary ->
        if necessary <> !selector_priority_active then (
          selector_priority_active := necessary;
          if necessary then (
            let nodes = topology_nodes source.raw.packed in
            selector_priority_nodes := nodes;
            adjust_topology_priority 1 nodes)
          else (
            adjust_topology_priority (-1) !selector_priority_nodes;
            selector_priority_nodes := [])))
      :: raw.node.demand_listeners;
    let weak_raw = Weak.create 1 in
    Weak.set weak_raw 0 (Some raw.packed);
    Hashtbl.replace compute_invalidators raw.handle.slot (fun () ->
        match Weak.get weak_raw 0 with
        | Some packed -> Core.clear_queue_mark packed
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
    match observers with
    | [] | [ _ ] -> observers
    | _ -> loop [] observers

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

  let reconcile_timer_demands () =
    match !timers with
    | [] -> ()
    | _ ->
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

  let sync_outcome f =
    match (try Ok (f ()) with exn -> Error exn) with
    | Ok (Ok ()) -> Edges.Success ()
    | Ok (Error error) -> Edges.Failure (Edges.Typed_failure error)
    | Error (Graph_error error as exn) ->
        edge_graph_error := Some error;
        Edges.Failure (Edges.Defect exn)
    | Error exn -> Edges.Failure (Edges.Defect exn)

  let edge_update = function
    | Edges.Initialized value -> Initialized value
    | Edges.Changed (old_value, new_value) ->
        Changed { old_value; new_value }

  (* One clock snapshot per sampling batch, shared by every timer bound to
     the same runtime. *)
  let make_now_sampler () =
    let sampled : (Eta.Runtime_contract.t * int) list ref = ref [] in
    fun (timer : timer) ->
      match
        List.find_opt
          (fun (rt, _) -> Eta.Runtime_contract.same_runtime rt timer.runtime)
          !sampled
      with
      | Some (_, now) -> now
      | None ->
          let now = timer.runtime.Eta.Runtime_contract.now_ms () in
          sampled := (timer.runtime, now) :: !sampled;
          now

  let prepare_timer_starts_now () =
    sampling_timer_starts := true;
    Fun.protect
      ~finally:(fun () -> sampling_timer_starts := false)
      (fun () ->
        let attempted = ref [] in
        let refreshed = ref false in
        let now_for = make_now_sampler () in
        try
          List.iter
            (fun (timer : timer) ->
              if timer.start_pending && timer.demand > 0 then (
                attempted := timer :: !attempted;
                let now = timer.reset (now_for timer) in
                if timer.demand > 0 then (
                  match timer.kind with
                  | Every _ | At _ ->
                      timer.refresh now;
                      refreshed := true
                  | Ticks _ | No_timer -> ());
                if timer.demand > 0 then timer.start_pending <- false
                else timer.rollback_refresh ()))
              (List.rev !timers);
          (!refreshed, !attempted)
        with exn ->
          List.iter (fun timer -> timer.rollback_refresh ()) !attempted;
          raise exn)

  let raise_cleanup_failures failures : 'a =
    match failures with
    | Edges.Defect exn :: _ -> raise exn
    | Edges.Interrupted exn :: _ -> raise exn
    | Edges.Typed_failure error :: _ ->
        (* Cleanup outcomes are unit hooks and daemon stops; a typed failure
           here is impossible, but keep it loud if it ever appears. *)
        raise (Failure (Format.asprintf "%a" Observer_error.pp error))
    | [] -> invalid_arg "Eta_signal: empty cleanup failure list"

  let run_edge_plan_sync ?(registration = false) plan =
    with_phase `Delivering @@ fun () ->
    (if registration then (
       let disposals = List.rev !pending_edge_disposals in
       pending_edge_disposals := [];
       List.iter (fun dispose -> dispose ()) disposals));
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
    if !timers <> [] then ignore (prepare_timer_starts_now ());
    edge_start_failed := false;
    let result =
      match Edges.run edges ~plan with
      | result -> result
      | exception exn ->
          (* Construction guards inside delivered callbacks record the graph
             error and abort delivery through the defect path; that error is
             a typed stabilize failure, not a raw defect. Genuine callback
             defects leave [edge_graph_error] unset and propagate raw. *)
          (match !edge_graph_error with
           | Some _ -> Error (Edges.Callback_failure (Edges.Defect exn))
           | None -> raise exn)
    in
    if
      Result.is_ok result
      && Edges.queued_timer_count edges > 0
      && List.for_all (fun (timer : timer) -> timer.demand = 0) !timers
    then
      ignore
        (Edges.run edges ~plan:[] :
          (unit, observer_error Edges.run_error) result);
    (match result with
    | Ok () -> ()
    | Error _ ->
        (if registration then (
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
           unlink_unnecessary_queued ()));
        ignore
          (Edges.drain_cleanup edges :
            (unit, observer_error Edges.run_error) result));
    (* Cleanup hooks queued during delivery itself (finish hooks, daemon stop
       hooks settled by a mid-delivery disposal) must still run before this
       edge plan completes; otherwise they would leak into the next plan. *)
    (match
       (Edges.drain_cleanup edges :
         (unit, observer_error Edges.run_error) result)
     with
     | Ok () -> ()
     | Error (Edges.Cleanup_failures errors) -> raise_cleanup_failures errors
     | Error
         ( Edges.Runtime_mismatch
         | Edges.Callback_failure (Edges.Typed_failure _) ) ->
        ()
     | Error (Edges.Callback_failure (Edges.Defect exn | Interrupted exn)) ->
        raise exn);
    match !edge_graph_error, result with
    | Some error, _ -> Error (error :> stabilize_error)
    | None, Ok () ->
        if had_callback_delivery then incr callback_delivery_count;
        Ok ()
    | None, Error Edges.Runtime_mismatch ->
        Error (`Runtime_mismatch :> stabilize_error)
    | None, Error (Edges.Callback_failure (Edges.Typed_failure error)) ->
        Error (`Observer_error error)
    | None, Error (Edges.Callback_failure (Edges.Defect exn)) -> raise exn
    | None, Error (Edges.Callback_failure (Edges.Interrupted exn)) -> raise exn
    | None, Error (Edges.Cleanup_failures errors) ->
        raise_cleanup_failures errors

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
                sync_outcome (fun () ->
                  Ok
                    (hook
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
          | Edges.Failure (Edges.Typed_failure _) as failure ->
              (* Typed failure settles the delivery: the event is consumed
                 without a callback, so the coalescing state must advance as
                 if the value had been observed. *)
              observer.deliver_pending <- false;
              observer.callback_pending <- false;
              observer.edge_base <- observer.current;
              failure
          | Edges.Failure (Edges.Defect _ | Edges.Interrupted _) as failure ->
              failure
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
    Execution.sync execution @@ fun () ->
    abandon_observer_now observer;
    match run_edge_plan_sync ~registration:true [] with
    | Ok () -> Ok ()
    | Error `Observer_error _ ->
        failwith "Eta_signal: observer registration cleanup failed"
    | Error (#graph_error as error) -> Error error

  let registration_with_cleanup observer_ref operation =
    match (try Ok (operation ()) with exn -> Error exn) with
    | Ok (Ok _ as ok) -> ok
    | Ok (Error _ as error) ->
        Option.iter abandon_observer_now !observer_ref;
        ignore (run_edge_plan_sync ~registration:true []);
        error
    | Error exn ->
        Option.iter abandon_observer_now !observer_ref;
        (try ignore (run_edge_plan_sync ~registration:true []) with _ -> ());
        raise exn

  module Observer = struct
    type 'a t = 'a observer
    type observer_finish = [ `Disposed | `Invalid_scope ]

    let observe ?cutoff ?on_finish ?on_update signal =
      Execution.sync execution @@ fun () ->
      let observer_ref = ref None in
      registration_with_cleanup observer_ref (fun () ->
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
                sync_outcome (fun () ->
                  if (Option.get !observer_ref).lifecycle <> Active then Ok ()
                  else callback (edge_update update))
              in
              (match outcome with
              | Edges.Success () ->
                  (Option.get !observer_ref).callback_pending <- false;
                  (Option.get !observer_ref).published <-
                    Some
                      (match update with
                      | Edges.Initialized value | Edges.Changed (_, value) ->
                          value);
                  ()
              | Edges.Failure _ -> ());
              outcome
          | Some _, None -> Edges.Success ()
        in
        (match result with
        | Ok observer -> observer_ref := Some observer
        | Error _ -> ());
        match result with
        | Error _ as error -> error
        | Ok observer ->
            observer.has_callback <- Option.is_some on_update;
            (match run_edge_plan_sync ~registration:true [] with
            | Ok () ->
                if observer.lifecycle = Invalid then Error `Invalid_scope
                else (
                  transfer_observer observer;
                  Ok observer)
            | Error `Observer_error _ ->
                failwith
                  "Eta_signal: impossible typed observer-registration failure"
            | Error (#graph_error as error) -> Error error))

    let read observer =
      Execution.sync execution @@ fun () ->
      match observer.lifecycle, observer.current with
      | Disposed, _ -> Error `Disposed_observer
      | Invalid, _ -> Error `Invalid_scope
      | Active, Some value -> Ok value
      | Active, None ->
          if !stabilization_attempts > observer.observed_attempt then
            Error `No_current_value
          else Error `Uninitialized_observer

    let dispose observer =
      Execution.sync execution @@ fun () ->
      (match observer.lifecycle with
      | Disposed -> ()
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
          Edges.dispose edges observer.edge
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
            + max 0 (necessary_before - necessary_count ()));
      if !sampling_timer_starts || !phase <> `Idle then Ok ()
      else
        (match run_edge_plan_sync ~registration:true [] with
        | Ok () -> Ok ()
        | Error `Observer_error _ ->
            failwith "Eta_signal: impossible typed disposal hook failure"
        | Error (#graph_error as error) -> Error error)
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
                         if s.input_key_comparison_count <> max_int then
                           keyed :=
                             { s with input_key_comparison_count =
                                        s.input_key_comparison_count + 1 })
                       ~init:()
                       ~f:(fun () key change ->
                         let s = !keyed in
                         if s.input_diff_event_count <> max_int then
                           keyed :=
                             { s with input_diff_event_count =
                                        s.input_diff_event_count + 1 };
                         match change with
                         | PLeft value -> emit key (Core.Left (Some value))
                         | PRight value -> emit key (Core.Right (Some value))
                         | PChanged (left, right) ->
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
      let rec initialize_added before = function
        | current when current == before -> ()
        | initialize :: rest ->
            initialize ();
            initialize_added before rest
        | [] ->
            invalid_arg "Eta_signal: keyed initializer registry changed"
      in
      let owner =
        Core.keyed_owner
          ~data_cutoff:(option_cutoff plan.data_cutoff)
          ~input:plan.input.raw ~input_ops ~output_ops
          ~build:(fun ~key ~data ->
            let previous_initializers = !initializers in
            let signal = { raw = data; timer = None } in
            let output = plan.build ~key ~data:signal in
            let wrapped =
              map (fun value ->
                let s = !keyed in
                if s.child_visit_count <> max_int then
                  keyed :=
                    { s with child_visit_count = s.child_visit_count + 1 };
                Option.iter
                  (fun owner ->
                    Core.clear_queue_mark owner.Core.keyed_signal.packed)
                  !owner_ref;
                value)
                output
            in
            Core.activate (Core.P wrapped.raw.node);
            initialize_added previous_initializers !initializers;
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
      if s.node_count <> max_int then keyed := { s with node_count = s.node_count + 1 };
      { raw = owner.Core.keyed_signal; timer = plan.input.timer }
  end

  let drain_edge_cleanup_sync () =
    let disposals = List.rev !pending_edge_disposals in
    pending_edge_disposals := [];
    List.iter (fun dispose -> dispose ()) disposals;
    let finishes = List.rev !pending_finishes in
    pending_finishes := [];
    List.iter (fun finish -> ignore (finish ())) finishes;
    ignore
      (Edges.drain_cleanup edges :
        (unit, observer_error Edges.run_error) result)

  let enqueue_uninitialized_necessary () =
    List.iter (fun enqueue -> enqueue ()) !initializers

  let enqueue_all_uninitialized_necessary () =
    Core.enqueue_all_uninitialized_necessary graph

  let stabilize () =
    Execution.sync execution @@ fun () ->
    if !phase = `Delivering then Error `Reentrant_stabilization
    else
      let first_pass () =
        enqueue_uninitialized_necessary ();
        Core.unlink_queued_descendants graph
          (List.map (fun (timer : timer) -> timer.source_node) !timers);
        incr stabilization_attempts;
        match with_phase `Planning (fun () -> Core.stabilize graph) with
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
            reconcile_timer_demands ();
            if
              not
                (List.exists
                   (fun (timer : timer) ->
                     timer.start_pending && timer.demand > 0)
                   !timers)
            then initializers := [];
            Ok (collect_observers ())
      in
      (match first_pass () with
      | Error error -> Error (error :> stabilize_error)
      | Ok initial_batch -> (
          let refreshed =
            match !timers with
            | [] -> false
            | _ ->
                let _started_refreshed, started =
                  match
                    (try
                       List.iter
                         (fun (timer : timer) ->
                           if timer.demand = 0 then timer.rollback_refresh ())
                         !timers;
                       Ok (prepare_timer_starts_now ())
                     with exn -> Error exn)
                  with
                  | Ok refreshed -> refreshed
                  | Error exn ->
                      drain_edge_cleanup_sync ();
                      raise exn
                in
                let started_admitted =
                  List.fold_left
                    (fun admitted (timer : timer) ->
                      (timer.demand > 0 && timer.admit_refresh ()) || admitted)
                    false started
                in
                let active_refreshed =
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
                      let now_for = make_now_sampler () in
                      List.iter
                        (fun timer -> timer.refresh (now_for timer))
                        timers;
                      ignore
                        (List.fold_left
                           (fun admitted timer ->
                             timer.admit_refresh () || admitted)
                           false timers);
                      true
                in
                started <> [] || started_admitted || active_refreshed
          in
          let second_pass () =
            let stale =
              Core.enqueue_stale_freshness graph ~bind_nodes
                ~custom_cutoff_nodes ~duplicate_dependency_nodes
            in
            if refreshed || stale then (
              enqueue_uninitialized_necessary ();
              enqueue_all_uninitialized_necessary ();
              match with_phase `Planning (fun () -> Core.stabilize graph) with
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
                  reconcile_timer_demands ();
                  Ok (collect_observers ()))
            else Ok initial_batch
          in
          (match second_pass () with
          | Error error -> Error (error :> stabilize_error)
          | Ok batch -> run_edge_plan_sync batch)))

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
    Execution.sync execution @@ fun () ->
    if graph.phase = Core.Idle then Core.release_unreachable_roots graph;
    let total, necessary, dirty = Core.public_node_counts graph in
    let total = ref total and necessary = ref necessary and dirty = ref dirty in
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
    let s = !keyed in
    let g = Core.keyed_stats_for graph in
    let keyed_node_count = ref 0 in
    let committed_child_count = ref 0 in
    let counted_keyed_nodes, counted_committed_children =
      Core.keyed_node_counts graph
    in
    keyed_node_count := counted_keyed_nodes;
    committed_child_count := counted_committed_children;
    let check_overflow name value =
      if value = max_int then Error (`Counter_overflow name) else Ok ()
    in
    let check_overflow_sum name a b =
      if a = max_int || b = max_int then Error (`Counter_overflow name)
      else if a > max_int - b then Error (`Counter_overflow name)
      else if a + b = max_int then Error (`Counter_overflow name)
      else Ok ()
    in
    let ( let* ) = Result.bind in
    let* () = check_overflow "stats keyed.reconciliation_count" g.keyed_reconciliation_count in
    let* () = check_overflow_sum "stats keyed.input_key_comparison_count" s.input_key_comparison_count g.keyed_input_key_comparison_count in
    let* () = check_overflow_sum "stats keyed.input_diff_event_count" s.input_diff_event_count g.keyed_input_diff_event_count in
    let* () = check_overflow_sum "stats keyed.child_visit_count" s.child_visit_count g.keyed_child_visit_count in
    let* () = check_overflow "stats keyed.provisional_addition_count" g.keyed_provisional_addition_count in
    let* () = check_overflow "stats keyed.committed_addition_count" g.keyed_committed_addition_count in
    let* () = check_overflow "stats keyed.committed_removal_count" g.keyed_committed_removal_count in
    let* () = check_overflow "stats keyed.reconciliation_rollback_count" g.keyed_reconciliation_rollback_count in
    let* () = check_overflow "stats keyed.node_count" !keyed_node_count in
    let* () =
      check_overflow "stats keyed.committed_child_count" !committed_child_count
    in
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
        keyed =
          {
            node_count = !keyed_node_count;
            committed_child_count = !committed_child_count;
            reconciliation_count = g.keyed_reconciliation_count;
            input_key_comparison_count =
              s.input_key_comparison_count + g.keyed_input_key_comparison_count;
            input_diff_event_count =
              s.input_diff_event_count + g.keyed_input_diff_event_count;
            child_visit_count = s.child_visit_count + g.keyed_child_visit_count;
            provisional_addition_count = g.keyed_provisional_addition_count;
            committed_addition_count = g.keyed_committed_addition_count;
            committed_removal_count = g.keyed_committed_removal_count;
            reconciliation_rollback_count = g.keyed_reconciliation_rollback_count;
          };
      }

  let to_dot ?(options = default_dot_options) () =
    Execution.sync execution @@ fun () ->
    Core.release_unreachable_roots graph;
    let buffer = Buffer.create 256 in
    Buffer.add_string buffer "digraph eta_signal {\n";
    Core.append_nodes_dot buffer graph
      ~only_necessary:(options.dot_scope = `Necessary)
      ~scope_label:
        (match options.dot_scope with
        | `Necessary -> "necessary"
        | `All_valid -> "all_valid"
        | `All_including_invalid -> "all_including_invalid")
      ~dot_state:options.dot_state
      ~dot_dynamic_scopes:options.dot_dynamic_scopes;
    if options.dot_dynamic_scopes && !scope_owners <> [] then
      Buffer.add_string buffer
        "  dynamic_scopes [label=\"scope=valid scope_id=sc0 scope_owner=s0 scope_parent=root\"];\n";
    if options.dot_scope = `All_including_invalid then begin
      let count = max 1 !dead_nodes in
      for dead = 1 to count do
        Buffer.add_string buffer
          (Printf.sprintf
             "  dead_s%d [label=\"dead_s%d kind=keyed_mapi valid=false scope=:invalid tombstone=true\"];\n"
             dead dead)
      done
    end;
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
    Buffer.contents buffer

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
                  let daemon_body () =
                    (* The daemon callback must resume on the graph owner
                       domain before it reads or mutates any timer state.
                       A violation escapes the callback and surfaces through
                       the runtime's daemon failure path. *)
                    ensure_context ();
                    Fun.protect
                      ~finally:(fun () -> cancel_ref := None)
                      (fun () ->
                        try
                          runtime.Eta.Runtime_contract.cancel_sub
                          @@ fun cancel_context ->
                          let cancel () =
                            runtime.Eta.Runtime_contract.cancel cancel_context
                              Timer_cancelled
                          in
                          cancel_ref := Some cancel;
                          if !stop_requested then cancel ()
                          else (
                            let rec loop () =
                              runtime.Eta.Runtime_contract.sleep
                                (sleep_duration runtime);
                              let accepted =
                                match !edge_timer_ref with
                                | None -> false
                                | Some edge_timer ->
                                    (match
                                       Edges.timer_wake_with edges ~runtime
                                         edge_timer ~generation
                                         ~admit:(fun () -> !admit_ref runtime)
                                     with
                                    | Ok accepted -> accepted
                                    | Error _ -> false)
                              in
                              if accepted then
                                match kind with
                                | At _ -> ()
                                | Every _ | Ticks _ | No_timer -> loop ()
                              else if
                                (not !stop_requested)
                                &&
                                match !edge_timer_ref with
                                | Some edge_timer ->
                                    Edges.timer_generation edge_timer
                                    = generation
                                | None -> false
                              then (
                                match kind with
                                | Ticks _ ->
                                    !admit_ref runtime;
                                    loop ()
                                | At _ | Every _ | No_timer -> ())
                            in
                            loop ());
                          `Stop_daemon
                        with exn ->
                          if
                            Option.is_some
                              (runtime.Eta.Runtime_contract
                                 .cancellation_reason exn)
                          then `Stop_daemon
                          else (
                            (match !edge_timer_ref with
                            | Some edge_timer ->
                                Edges.daemon_failed edges edge_timer
                                  ~generation
                            | None -> ());
                            `Stop_daemon))
                  in
                  (try
                     runtime.Eta.Runtime_contract.fork_daemon
                       runtime.Eta.Runtime_contract.root_scope daemon_body;
                     startup_cleanup := None;
                     Edges.Success stop
                   with exn ->
                     edge_start_failed := true;
                     Edges.Failure (Edges.Defect exn))
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
              Core.cancel_admission graph source.source.signal.packed);
      commit_refresh :=
        (fun () ->
          speculative := None;
          force_source := false);
      let reset now =
        !begin_refresh ();
        sample := now;
        now
      in
      let refresh now =
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
          refresh (active_runtime.Eta.Runtime_contract.now_ms ()));
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
          now_ms = runtime.Eta.Runtime_contract.now_ms;
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
          E.sync_result (fun () ->
            ensure_context ();
            let milliseconds = runtime.Eta.Runtime_contract.now_ms () in
            let signal, _ =
              make_timer ~last_sample:milliseconds runtime
                (Every (Eta.Duration.to_ms every))
                { runtime; milliseconds }
                (fun _ now _ -> Some ({ runtime; milliseconds = now }, now))
            in
            Ok signal)

    let deadline time =
      let open Eta.Syntax in
      let* runtime = current_runtime () in
      if not (Eta.Runtime_contract.same_runtime runtime time.runtime) then
        E.fail `Runtime_mismatch
      else
        E.sync_result (fun () ->
          ensure_context ();
          let now = runtime.Eta.Runtime_contract.now_ms () in
          if time.milliseconds <= now then Error `Past_deadline
          else
            let signal, _ =
              make_timer ~last_sample:now runtime (At time.milliseconds)
                false
                (fun _ now sample -> Some (now >= time.milliseconds, sample))
            in
            Ok signal)

    let after duration =
      let open Eta.Syntax in
      let delta = Eta.Duration.to_ms duration in
      if delta <= 0 then E.fail `Past_deadline
      else
        let* runtime = current_runtime () in
        E.sync_result (fun () ->
          ensure_context ();
          let now = runtime.Eta.Runtime_contract.now_ms () in
          if now > max_int - delta then Error `Deadline_overflow
          else
            let deadline = now + delta in
            let signal, _ =
              make_timer ~last_sample:now runtime (At deadline) false
                (fun _ now sample -> Some (now >= deadline, sample))
            in
            Ok signal)

    let interval duration =
      let open Eta.Syntax in
      match validate duration with
      | Error error -> E.fail error
      | Ok () ->
          let* runtime = current_runtime () in
          E.sync_result (fun () ->
            ensure_context ();
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
            Ok signal)
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
