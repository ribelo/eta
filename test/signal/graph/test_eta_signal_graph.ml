module Graph = Eta_signal_testable.Graph
module Bind = Eta_signal_testable.Bind
module Id = Eta_signal_testable.Id
module Observer = Eta_signal_testable.Observer_core
module Pass = Eta_signal_testable.Stabilization_pass
module Transaction = Eta_signal_testable.Transaction

module Direct_runtime = struct
  type scope = unit
  type cancel_context = unit
  type 'a promise = 'a option ref
  type 'a resolver = 'a option ref
  type 'a stream = 'a Stdlib.Queue.t

  let root_scope = ()
  let now_ms () = 0
  let sleep _duration = ()
  let protect f = f ()
  let run_scope ?name:_ f = f ()
  let fail_scope ?bt:_ () exn = raise exn
  let fork () f = f ()
  let fork_daemon () f = ignore (f () : [ `Stop_daemon ])
  let await_cancel () = failwith "Direct_runtime.await_cancel"
  let yield () = ()
  let check () = ()

  let create_promise () =
    let cell = ref None in
    (cell, cell)

  let resolve_promise resolver value =
    match !resolver with
    | Some _ -> invalid_arg "Direct_runtime.resolve_promise: already resolved"
    | None -> resolver := Some value

  let await_promise promise =
    match !promise with
    | Some value -> value
    | None -> failwith "Direct_runtime.await_promise: unresolved"

  let create_stream _capacity = Stdlib.Queue.create ()
  let stream_add stream value = Stdlib.Queue.add value stream

  let stream_take stream =
    if Stdlib.Queue.is_empty stream then
      failwith "Direct_runtime.stream_take: empty"
    else Stdlib.Queue.take stream

  let stream_take_nonblocking stream =
    if Stdlib.Queue.is_empty stream then None else Some (Stdlib.Queue.take stream)

  let with_worker_context f = f ()
  let in_worker_context () = false
  let cancellation_reason _ = None
  let multiple_exceptions _ = None
  let cancel_sub f = f ()
  let cancel () exn = raise exn
  let current_fiber_id () = 0
  let with_fiber_identity f = f ()

  let locals : (int, Eta.Runtime_contract.local_binding list) Hashtbl.t =
    Hashtbl.create 8

  let local_get local =
    match
      Hashtbl.find_opt locals
        (Eta.Runtime_contract.Backend.local_id local)
    with
    | None -> None
    | Some bindings ->
        List.find_map
          (Eta.Runtime_contract.Backend.local_binding_value local)
          bindings

  let local_with_binding local value f =
    let id = Eta.Runtime_contract.Backend.local_id local in
    let previous = Hashtbl.find_opt locals id in
    let stack = Option.value previous ~default:[] in
    Hashtbl.replace locals id
      (Eta.Runtime_contract.Local_binding (local, value) :: stack);
    Fun.protect
      ~finally:(fun () ->
        match previous with
        | Some stack -> Hashtbl.replace locals id stack
        | None -> Hashtbl.remove locals id)
      f
end

module Direct = Eta.Runtime.Make (Direct_runtime)

type live = {
  mutable snapshot : (int, unit) Observer.Snapshot.t;
}

type observer = {
  id : int;
  active : bool;
  mutable live : live option;
}

type scope = {
  scope_id : int;
  mutable scope_nodes : int list;
}

type scope_context = {
  mutable current_scope : scope option;
}

type node = {
  node_id : int;
  node_scope : scope option;
  mutable node_dependencies : int list;
}

type compute_node = {
  compute_id : int;
  mutable compute_seen_generation : int;
  mutable compute_changed_seen : bool;
  mutable compute_computing : bool;
  mutable compute_computed_generation : int;
  mutable compute_current : int;
}

type invalidating_node = {
  invalid_id : int;
  mutable invalid_valid : bool;
  mutable invalid_dependencies : invalidating_node list;
  mutable invalid_dependents : invalidating_node list;
  invalid_kind_scope : int option;
}

type dead_node = {
  dead_id : Id.signal;
  dead_label : string;
}

type demand_node = {
  demand_id : Id.signal;
  demand_live : bool;
  demand_timer : string option;
  mutable demand_children : demand_node list;
}

let record events event =
  events := !events @ [ event ]

let check_cap (_ : Graph.lane_access) = ()

let graph_lane_effect graph f =
  Graph.with_lane_access graph
    ~leaf_name:"test_eta_signal_graph"
    ~depth_local:(Eta.Runtime_contract.create_local ())
    ~hooks:
      (Graph.lane_hooks ~note_waiter_enqueued:ignore
         ~note_waiter_compaction:ignore)
    ~after_acquired:(fun () -> Eta.Effect.unit)
    f

let run_effect label eff =
  let runtime = Direct.create () in
  match Direct.run runtime eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error _ -> Alcotest.fail (label ^ " failed")

let staging_commit_plan ?(preflight = fun _staging -> ())
    ?(commit_bind = fun _staging _bind -> [])
    ?(prepare_signal = fun _staging _node -> ())
    ?(commit_timer_refresh = fun _timer -> ())
    ?(commit_signal = fun _node -> ()) () =
  Graph.staging_commit_plan ~preflight
    ~binds:(Graph.staging_bind_commit_plan ~commit:commit_bind)
    ~signals:
      (Graph.staging_signal_commit_plan ~prepare_signal ~commit_signal)
    ~timers:(Graph.staging_timer_commit_plan ~commit:commit_timer_refresh)

let stabilization_pure_ops
    ?(release_pending_marks = fun _context _pending -> ())
    ?(observer_delivery =
      fun _context _staging ->
        let selection =
          Observer.delivery_selection_plan ~active:(fun _observer -> false)
            ~compare:(fun _left _right -> 0)
        in
        Observer.delivery_collection ~selection
          ~events:
            (Observer.delivery_event_plan
               ~collect_event:(fun _context _observer -> None)
               ~mark_pending:(fun _context _events -> ())))
    ?(stage_pending = fun _context _staging _pending -> ())
    ?(plan_staged_binds = fun _context _staging _observers -> ())
    ?(staging = fun _context _staging -> staging_commit_plan ())
    ?(update_necessity = fun _context -> ()) () =
  Graph.stabilization_pure_ops
    ~pending:
      (Graph.stabilization_pending_plan
         ~release_marks:release_pending_marks ~stage:stage_pending)
    ~observers:
      (Graph.stabilization_observer_plan ~delivery:observer_delivery
         ~plan_staged_binds)
    ~commit:
      (Graph.stabilization_commit_plan ~staging ~update_necessity)

let with_graph_lane graph f =
  run_effect "lane access" (graph_lane_effect graph f)

let empty_stabilization_ops graph =
  let pure =
    stabilization_pure_ops
      ~staging:(fun _context _staging -> staging_commit_plan ())
      ()
  in
  let rollback =
    Graph.stabilization_rollback_ops
      ~rollback_staging:(fun _context _staging -> [])
      ~mark_observers_failed_without_current:(fun _context _observers -> ())
      ~requeue_pending:(fun _context _pending -> ())
  in
  Graph.stabilization_ops
    ~classify_graph_error:(fun _ -> None)
    ~pure ~rollback

let run_empty_stabilization graph =
  with_graph_lane graph (fun lane ->
      Graph.run_stabilization graph lane ~timer_refresh:None
        (empty_stabilization_ops graph))

let create_observer ?(active = true) id =
  {
    id;
    active;
    live =
      Some
        {
          snapshot =
            Observer.Snapshot.create
              ~value:Observer.Value.uninitialized
              ~delivery:Observer.Delivery.Observer_never_delivered;
        };
  }

let test_observer_registry_traversal_uses_lane () =
  let graph =
    Graph.create ~create_scope_context:(fun () -> ())
      ~create_stream_bridge_metrics:(fun () -> ()) ()
  in
  let first = create_observer 1 in
  let inactive = create_observer ~active:false 0 in
  let invalid = create_observer ~active:false 3 in
  let second = create_observer 2 in
  let observer_identity =
    Graph.observer_identity ~same:(fun left right -> left.id = right.id)
  in
  let observer_count_plan =
    Graph.observer_count_plan
      ~active:(fun observer -> observer.active)
      ~invalid:(fun observer -> not observer.active)
  in
  let active_hooks, observer_counts, even_ids =
    with_graph_lane graph (fun lane ->
        Graph.add_observer graph lane second;
        Graph.add_observer graph lane invalid;
        Graph.add_observer graph lane inactive;
        Graph.add_observer graph lane first;
        Graph.remove_observer graph lane observer_identity inactive;
        ( Graph.collect_observer_cleanup_hooks graph lane
            (Graph.observer_cleanup
               ~selected:(fun observer -> observer.active)
               ~cleanup:(fun observer -> [ observer.id ])),
          Graph.observer_counts graph lane observer_count_plan,
          Graph.collect_observer_diagnostics graph lane
            (Graph.observer_diagnostics
               ~visible:(fun observer -> observer.id mod 2 = 0)
               ~diagnostic:(fun observer -> observer.id)) ))
  in
  Alcotest.(check (list int)) "active hooks" [ 1; 2 ] active_hooks;
  Alcotest.(check int) "active count" 2
    (Graph.observer_counts_active observer_counts);
  Alcotest.(check int) "invalid count" 1
    (Graph.observer_counts_invalid observer_counts);
  Alcotest.(check (list int)) "even ids" [ 2 ] even_ids

let update_label = function
  | Observer.Update.Initialized value ->
      "initialized:" ^ string_of_int value
  | Observer.Update.Changed { old_value; new_value } ->
      "changed:" ^ string_of_int old_value ^ "->"
      ^ string_of_int new_value

let scoped_graph scope_context =
  Graph.create ~create_scope_context:(fun () -> scope_context)
    ~create_stream_bridge_metrics:(fun () -> ()) ()

let test_scope_ops =
  Graph.scope_ops
    ~current:(fun context -> context.current_scope)
    ~require_valid_current:(fun context ->
      match context.current_scope with
      | Some scope -> Ok scope
      | None -> Error `Ambiguous_scope)
    ~with_current:(fun context scope f ->
      let previous = context.current_scope in
      context.current_scope <- Some scope;
      Fun.protect ~finally:(fun () -> context.current_scope <- previous) f)

let live_nodes_from_cells _keep cells = (cells, cells)

let test_live_registry =
  Graph.live_node_registry ~collect_live_nodes:live_nodes_from_cells

let collect_demand_live_nodes keep cells =
  let cells = List.filter (fun node -> node.demand_live && keep node) cells in
  (cells, cells)

let demand_scope_ops =
  Graph.scope_ops
    ~current:(fun () -> None)
    ~require_valid_current:(fun () -> Error `Ambiguous_scope)
    ~with_current:(fun () (_scope : unit) f -> f ())

let create_demand_node graph ?timer ?(live = true) () =
  let lifecycle =
    Graph.node_lifecycle
      ~validate_dependency:(fun (_ : unit) -> ())
      ~create:(fun ~id ~scope:_ ->
        {
          demand_id = id;
          demand_live = live;
          demand_timer = timer;
          demand_children = [];
        })
      ~attach_dependency:(fun ~parent:_ ~child:(_ : unit) -> ())
      ~add_to_scope:(fun () _node -> ())
      ~pack:Fun.id ~create_weak:Fun.id
  in
  match Graph.create_live_node graph demand_scope_ops lifecycle ~dependencies:[] with
  | Ok node -> node
  | Error err ->
      Alcotest.failf "unexpected graph error: %s"
        (Format.asprintf "%a" Eta_signal_testable.Error.pp_graph_error err)

let demand_reachable_ops =
  Graph.reachable_ops ~id:(fun node -> node.demand_id)
    ~valid:(fun node -> node.demand_live)
    ~children:(fun node -> node.demand_children)

let demand_live_registry =
  Graph.live_node_registry ~collect_live_nodes:collect_demand_live_nodes

let optional_demand_roots =
  Graph.demand_roots ~demand:Option.is_some ~root:(function
    | Some node -> node
    | None -> invalid_arg "optional demand root is missing")

let demand_reachable_plan =
  Graph.reachable_plan ~ops:demand_reachable_ops
    ~registry:demand_live_registry ~roots:optional_demand_roots

let demand_timer_source =
  Graph.timer_demand_source ~reachable:demand_reachable_plan
    ~timer:(fun node ->
      Option.map (fun timer -> (node.demand_id, timer)) node.demand_timer)

let compute_ops =
  Graph.compute_ops ~node:(fun node -> node) ~pack:(fun node -> node)
    ~seen_generation:(fun node -> node.compute_seen_generation)
    ~set_seen_generation:(fun node generation ->
      node.compute_seen_generation <- generation)
    ~changed_seen:(fun node -> node.compute_changed_seen)
    ~set_changed_seen:(fun node changed -> node.compute_changed_seen <- changed)
    ~computing:(fun node -> node.compute_computing)
    ~set_computing:(fun node computing -> node.compute_computing <- computing)
    ~computed_generation:(fun node -> node.compute_computed_generation)
    ~set_computed_generation:(fun node generation ->
      node.compute_computed_generation <- generation)

let invalidating_node ?kind_scope id =
  {
    invalid_id = id;
    invalid_valid = true;
    invalid_dependencies = [];
    invalid_dependents = [];
    invalid_kind_scope = kind_scope;
  }

let invalidating_edge_ops events =
  let identity =
    Graph.node_identity ~id:(fun node -> node.invalid_id)
      ~equal_id:Int.equal
  in
  Graph.edge_ops ~identity
    ~dependencies:(fun node -> node.invalid_dependencies)
    ~set_dependencies:(fun node dependencies ->
      record events
        ("dependencies:" ^ string_of_int node.invalid_id ^ ":"
       ^ string_of_int (List.length dependencies));
      node.invalid_dependencies <- dependencies)
    ~dependents:(fun node -> node.invalid_dependents)
    ~set_dependents:(fun node dependents ->
      record events
        ("dependents:" ^ string_of_int node.invalid_id ^ ":"
       ^ string_of_int (List.length dependents));
      node.invalid_dependents <- dependents)

let test_create_live_node_owns_lifecycle_context () =
  let events = ref [] in
  let scope = { scope_id = 42; scope_nodes = [] } in
  let graph = scoped_graph { current_scope = Some scope } in
  let lifecycle =
    Graph.node_lifecycle
      ~validate_dependency:(fun dependency ->
        record events ("validate:" ^ string_of_int dependency))
      ~create:(fun ~id ~scope ->
        let id = Id.signal_int id in
        let scope_label =
          match scope with
          | Some scope -> "scope:" ^ string_of_int scope.scope_id
          | None -> "no_scope"
        in
        record events ("create:" ^ string_of_int id ^ ":" ^ scope_label);
        { node_id = id; node_scope = scope; node_dependencies = [] })
      ~attach_dependency:(fun ~parent ~child ->
        record events
          ("attach:" ^ string_of_int parent.node_id ^ "<-"
         ^ string_of_int child);
        parent.node_dependencies <- parent.node_dependencies @ [ child ])
      ~add_to_scope:(fun scope node ->
        record events
          ("scope:" ^ string_of_int scope.scope_id ^ ":"
         ^ string_of_int node.node_id);
        scope.scope_nodes <- scope.scope_nodes @ [ node.node_id ])
      ~pack:(fun node ->
        record events ("pack:" ^ string_of_int node.node_id);
        node)
      ~create_weak:(fun node ->
        record events ("weak:" ^ string_of_int node.node_id);
        node)
  in
  let node =
    match Graph.create_live_node graph test_scope_ops lifecycle
            ~dependencies:[ 7; 9 ] with
    | Ok node -> node
    | Error err ->
        Alcotest.failf "unexpected graph error: %s"
          (Format.asprintf "%a" Eta_signal_testable.Error.pp_graph_error err)
  in
  Alcotest.(check int) "node id" 0 node.node_id;
  Alcotest.(check (option int))
    "node scope" (Some 42)
    (Option.map (fun scope -> scope.scope_id) node.node_scope);
  Alcotest.(check (list int)) "dependencies" [ 7; 9 ]
    node.node_dependencies;
  Alcotest.(check (list int)) "scope nodes" [ 0 ] scope.scope_nodes;
  let live_node_ids =
    with_graph_lane graph (fun lane ->
        Graph.live_nodes graph lane test_live_registry)
    |> List.map (fun node -> node.node_id)
  in
  Alcotest.(check (list int)) "live nodes" [ 0 ] live_node_ids;
  Alcotest.(check (list string))
    "events"
    [
      "validate:7";
      "validate:9";
      "create:0:scope:42";
      "attach:0<-7";
      "attach:0<-9";
      "scope:42:0";
      "pack:0";
      "weak:0";
    ]
    !events

let test_invalidate_live_node_owns_lifecycle_order () =
  let events = ref [] in
  let graph =
    Graph.create ~create_scope_context:(fun () -> ())
      ~create_stream_bridge_metrics:(fun () -> ()) ()
  in
  let dependency = invalidating_node 0 in
  let root = invalidating_node ~kind_scope:10 1 in
  let dependent = invalidating_node 2 in
  dependency.invalid_dependents <- [ root ];
  root.invalid_dependencies <- [ dependency ];
  root.invalid_dependents <- [ dependent ];
  dependent.invalid_dependencies <- [ root ];
  let lifecycle =
    Graph.node_invalidation
      ~valid:(fun node -> node.invalid_valid)
      ~set_invalid:(fun node ->
        record events ("invalid:" ^ string_of_int node.invalid_id);
        node.invalid_valid <- false)
      ~timer_hooks:(fun node ->
        record events ("timer:" ^ string_of_int node.invalid_id);
        [ "timer-hook:" ^ string_of_int node.invalid_id ])
      ~tombstone:(fun node ->
        record events ("tombstone:" ^ string_of_int node.invalid_id);
        {
          dead_id = Id.signal node.invalid_id;
          dead_label = "dead:" ^ string_of_int node.invalid_id;
        })
      ~tombstone_id:(fun dead -> dead.dead_id)
      ~observer_hooks:(fun node ->
        record events ("observer:" ^ string_of_int node.invalid_id);
        [ "observer-hook:" ^ string_of_int node.invalid_id ])
      ~kind_hooks:(fun ~invalidate_scope node ->
        record events ("kind:" ^ string_of_int node.invalid_id);
        match node.invalid_kind_scope with
        | None -> []
        | Some scope -> invalidate_scope ~prune:false scope)
  in
  let invalidate_scope ?(prune = true) scope =
    record events
      ("scope:" ^ string_of_int scope ^ ":prune:" ^ string_of_bool prune);
    [ "scope-hook:" ^ string_of_int scope ]
  in
  let hooks =
    with_graph_lane graph (fun lane ->
        Graph.invalidate_live_node graph lane (invalidating_edge_ops events)
          lifecycle ~invalidate_scope root)
  in
  Alcotest.(check (list string))
    "hooks"
    [
      "timer-hook:1";
      "observer-hook:1";
      "timer-hook:2";
      "observer-hook:2";
      "scope-hook:10";
    ]
    hooks;
  Alcotest.(check (list string))
    "events"
    [
      "timer:1";
      "invalid:1";
      "tombstone:1";
      "observer:1";
      "dependents:0:0";
      "dependencies:1:0";
      "dependents:1:0";
      "timer:2";
      "invalid:2";
      "tombstone:2";
      "observer:2";
      "dependents:1:0";
      "dependencies:2:0";
      "dependents:2:0";
      "kind:2";
      "kind:1";
      "scope:10:prune:false";
    ]
    !events;
  Alcotest.(check bool) "root invalid" false root.invalid_valid;
  Alcotest.(check bool) "dependent invalid" false dependent.invalid_valid;
  Alcotest.(check (list int))
    "dependency dependents cleared" []
    (List.map (fun node -> node.invalid_id) dependency.invalid_dependents);
  Alcotest.(check (list int))
    "root dependencies cleared" []
    (List.map (fun node -> node.invalid_id) root.invalid_dependencies);
  Alcotest.(check int) "dead count" 2
    (with_graph_lane graph (fun lane -> Graph.dead_node_count graph lane));
  Alcotest.(check (list string))
    "dead nodes"
    [ "dead:2"; "dead:1" ]
    (with_graph_lane graph (fun lane ->
         Graph.map_dead_nodes graph lane ~f:(fun dead -> dead.dead_label)))

let test_compute_cached_owns_cache_and_cycle_dispatch () =
  let events = ref [] in
  let graph =
    Graph.create ~create_scope_context:(fun () -> ())
      ~create_stream_bridge_metrics:(fun () -> ()) ()
  in
  let node =
    {
      compute_id = 1;
      compute_seen_generation = -1;
      compute_changed_seen = false;
      compute_computing = false;
      compute_computed_generation = -1;
      compute_current = 0;
    }
  in
  let current node =
    record events ("current:" ^ string_of_int node.compute_current);
    node.compute_current
  in
  let cycle node =
    record events ("cycle:" ^ string_of_int node.compute_id);
    (node.compute_current, false)
  in
  let compute node =
    record events ("compute:" ^ string_of_int node.compute_id);
    node.compute_current <- 10;
    (node.compute_current, true)
  in
  with_graph_lane graph (fun lane ->
      Graph.set_generation graph lane 1;
      Alcotest.(check (pair int bool))
        "first compute" (10, true)
        (Graph.compute_cached graph lane compute_ops node ~current ~cycle
           ~compute);
      Alcotest.(check int) "seen generation" 1 node.compute_seen_generation;
      Alcotest.(check bool) "changed seen" true node.compute_changed_seen;
      Alcotest.(check bool) "guard cleared" false node.compute_computing;
      Alcotest.(check (pair int bool))
        "cached compute" (10, true)
        (Graph.compute_cached graph lane compute_ops node ~current ~cycle
           ~compute);
      node.compute_computing <- true;
      Graph.set_generation graph lane 2;
      Alcotest.(check (pair int bool))
        "cycle result" (10, false)
        (Graph.compute_cached graph lane compute_ops node ~current ~cycle
           ~compute));
  Alcotest.(check int)
    "cycle does not publish generation" 1 node.compute_seen_generation;
  Alcotest.(check bool)
    "existing guard remains owned by caller" true node.compute_computing;
  Alcotest.(check (list string))
    "events"
    [ "compute:1"; "current:10"; "cycle:1" ]
    !events

let test_generation_owned_by_graph () =
  let graph =
    Graph.create ~create_scope_context:(fun () -> ())
      ~create_stream_bridge_metrics:(fun () -> ()) ()
  in
  Alcotest.(check int)
    "initial generation" 0
    (with_graph_lane graph (fun lane -> Graph.generation graph lane));
  let finish = Graph.create_stabilization_finish () in
  let result = run_empty_stabilization graph in
  let hooks =
    with_graph_lane graph (fun lane ->
        Graph.record_stabilization_result finish lane result)
  in
  Pass.result result
    ~pure_ok:(fun ~hooks:_ ~events ~delivering_token:_ ->
      Alcotest.(check (list string)) "hooks" [] hooks;
      Alcotest.(check (list string)) "events" [] events;
      with_graph_lane graph (fun lane ->
          Graph.finish_recorded_stabilization graph lane finish))
    ~graph_error:(fun ~hooks:_ err ->
      Alcotest.failf "unexpected graph error: %s"
        (Format.asprintf "%a" Eta_signal_testable.Error.pp_graph_error err))
    ~defect:(fun ~hooks:_ exn _backtrace ->
      Alcotest.failf "unexpected defect: %s" (Printexc.to_string exn));
  Alcotest.(check int)
    "advanced generation" 1
    (with_graph_lane graph (fun lane -> Graph.generation graph lane));
  with_graph_lane graph (fun lane -> Graph.set_generation graph lane max_int);
  let result = run_empty_stabilization graph in
  Pass.result result
    ~pure_ok:(fun ~hooks:_ ~events:_ ~delivering_token:_ ->
      Alcotest.fail "expected generation overflow")
    ~graph_error:(fun ~hooks err ->
      Alcotest.(check (list string)) "hooks" [] hooks;
      match err with
      | `Counter_overflow name
        when String.equal name "stabilization generation" ->
          ()
      | err ->
          Alcotest.failf "unexpected graph error: %s"
            (Format.asprintf "%a" Eta_signal_testable.Error.pp_graph_error
               err))
    ~defect:(fun ~hooks:_ exn _backtrace ->
      Alcotest.failf "unexpected defect: %s" (Printexc.to_string exn));
  Alcotest.(check int) "overflow preserves generation" max_int
    (with_graph_lane graph (fun lane -> Graph.generation graph lane))

let test_stabilization_delivery_ops_own_counter_and_finish () =
  let events = ref [] in
  let graph =
    Graph.create ~create_scope_context:(fun () -> ())
      ~create_stream_bridge_metrics:(fun () -> ()) ()
  in
  let finish = Graph.create_stabilization_finish () in
  let result = run_empty_stabilization graph in
  let hooks =
    with_graph_lane graph (fun lane ->
        Graph.record_stabilization_result finish lane result)
  in
  Pass.result result
    ~pure_ok:(fun ~hooks:_ ~events:_ ~delivering_token:_ ->
      Alcotest.(check (list string)) "hooks" [] hooks)
    ~graph_error:(fun ~hooks:_ err ->
      Alcotest.failf "unexpected graph error: %s"
        (Format.asprintf "%a" Eta_signal_testable.Error.pp_graph_error err))
    ~defect:(fun ~hooks:_ exn _backtrace ->
      Alcotest.failf "unexpected defect: %s" (Printexc.to_string exn));
  let context =
    Graph.stabilization_delivery_context
      ~run_pending_cleanup:(fun () ->
        Eta.Effect.sync (fun () -> record events "cleanup"))
      ~run_events:(fun delivery_events ->
        Eta.Effect.sync (fun () ->
            List.iter
              (fun event -> record events ("event:" ^ event))
              delivery_events))
      ~with_lane_access:(graph_lane_effect graph)
  in
  let delivery_ops = Graph.stabilization_delivery_ops graph finish context in
  run_effect "delivery" (Pass.deliver delivery_ops [ "one"; "two" ]);
  Alcotest.(check (list string))
    "events"
    [ "cleanup"; "event:one"; "event:two"; "cleanup" ]
    !events;
  Alcotest.(check int)
    "callback delivery count" 1
    (with_graph_lane graph (fun lane ->
         Graph.counter graph lane Graph.Callback_delivery_count));
  Alcotest.(check bool)
    "finish cleared" false
    (Graph.stabilization_finish_pending finish)

let test_computed_nodes_are_staging_scoped () =
  let events = ref [] in
  let graph =
    Graph.create ~create_scope_context:(fun () -> ())
      ~create_stream_bridge_metrics:(fun () -> ()) ()
  in
  let node =
    {
      compute_id = 7;
      compute_seen_generation = 0;
      compute_changed_seen = false;
      compute_computing = false;
      compute_computed_generation = 0;
      compute_current = 0;
    }
  in
  let pure =
    stabilization_pure_ops
      ~release_pending_marks:(fun _context _pending -> ())
      ~stage_pending:(fun context staging _pending ->
        Graph.remember_computed graph context staging compute_ops node;
        record events "remember")
      ~plan_staged_binds:(fun _context _staging _observers -> ())
      ~staging:(fun context staging ->
        Graph.iter_computed graph context staging ~f:(fun node ->
            record events ("iter:" ^ string_of_int node.compute_id));
        staging_commit_plan
          ~preflight:(fun callback_staging ->
            Graph.iter_computed graph context callback_staging ~f:(fun node ->
                record events
                  ("preflight:" ^ string_of_int node.compute_id)))
          ~commit_bind:(fun _staging _bind -> [])
          ~prepare_signal:(fun _staging node ->
            record events ("prepare:" ^ string_of_int node.compute_id))
          ~commit_timer_refresh:(fun _timer -> ())
          ~commit_signal:(fun node ->
            record events ("commit:" ^ string_of_int node.compute_id))
          ())
      ~update_necessity:(fun _context -> record events "update_necessity")
      ()
  in
  let rollback =
    Graph.stabilization_rollback_ops
      ~rollback_staging:(fun _context _staging -> [])
      ~mark_observers_failed_without_current:(fun _context _observers -> ())
      ~requeue_pending:(fun _context _pending -> ())
  in
  let finish = Graph.create_stabilization_finish () in
  let result =
    with_graph_lane graph (fun lane ->
        Graph.run_stabilization graph lane ~timer_refresh:None
          (Graph.stabilization_ops
             ~classify_graph_error:(fun _ -> None)
             ~pure ~rollback))
  in
  let hooks =
    with_graph_lane graph (fun lane ->
        Graph.record_stabilization_result finish lane result)
  in
  Pass.result result
    ~pure_ok:(fun ~hooks:_ ~events:delivery_events ~delivering_token:_ ->
      Alcotest.(check (list string)) "hooks" [] hooks;
      Alcotest.(check (list string)) "delivery events" [] delivery_events;
      with_graph_lane graph (fun lane ->
          Graph.finish_recorded_stabilization graph lane finish))
    ~graph_error:(fun ~hooks:_ err ->
      Alcotest.failf "unexpected graph error: %s"
        (Format.asprintf "%a" Eta_signal_testable.Error.pp_graph_error err))
    ~defect:(fun ~hooks:_ exn _backtrace ->
      Alcotest.failf "unexpected defect: %s" (Printexc.to_string exn));
  Alcotest.(check (list string))
    "events"
    [
      "remember";
      "iter:7";
      "preflight:7";
      "prepare:7";
      "commit:7";
      "update_necessity";
    ]
    !events

let test_stage_bind_switch_owns_transaction_staging () =
  let events = ref [] in
  let graph =
    Graph.create ~create_scope_context:(fun () -> ())
      ~create_stream_bridge_metrics:(fun () -> ()) ()
  in
  let staged =
    Transaction.create_staged
      (Bind.switch ~source_value:0 ~inner:"old" ~scope:1)
  in
  let stage_twice lane staging =
    Graph.stage_bind_switch graph lane staging "bind" staged ~source_value:1
      ~inner:"inner" ~scope:2;
    Graph.stage_bind_switch graph lane staging "bind" staged ~source_value:2
      ~inner:"next" ~scope:3;
    let snapshot = Graph.read_effective graph staged in
    Alcotest.(check (option string)) "staged inner" (Some "next")
      (Bind.inner snapshot);
    Alcotest.(check (option int)) "staged scope" (Some 3)
      (Bind.inner_scope snapshot);
    let invalidation_plan =
      Graph.staged_bind_invalidation_plan ~init:[]
        ~staged_switch:(fun bind ->
          Alcotest.(check string) "bind" "bind" bind;
          Bind.staged_switch ~owner:(Some "owner")
            ~current:(Transaction.current staged)
            ~staged:(Graph.staged_value graph lane staging staged)
          |> Bind.pack_staged_switch)
        ~collect_old_scope:(fun acc ~owner scope -> (owner, scope) :: acc)
    in
    let collected =
      match
        Graph.collect_staged_bind_switch_invalidations graph lane staging
          invalidation_plan
      with
      | Ok collected -> collected
      | Error err ->
          Alcotest.failf "unexpected graph error: %s"
            (Format.asprintf "%a" Eta_signal_testable.Error.pp_graph_error
               err)
    in
    Alcotest.(check (list (pair string int)))
      "old scope invalidation" [ ("owner", 1) ] collected;
    let missing_owner_plan =
      Graph.staged_bind_invalidation_plan ~init:[]
        ~staged_switch:(fun _bind ->
          Bind.staged_switch ~owner:None ~current:(Transaction.current staged)
            ~staged:(Graph.staged_value graph lane staging staged)
          |> Bind.pack_staged_switch)
        ~collect_old_scope:(fun acc ~owner:_ _scope -> acc)
    in
    match
      Graph.collect_staged_bind_switch_invalidations graph lane staging
        missing_owner_plan
    with
    | Error `Invalid_scope -> ()
    | Ok _ -> Alcotest.fail "expected invalid scope"
    | Error err ->
        Alcotest.failf "expected invalid scope, got %s"
          (Format.asprintf "%a" Eta_signal_testable.Error.pp_graph_error err)
  in
  let pure =
    stabilization_pure_ops
      ~release_pending_marks:(fun _context _pending -> ())
      ~stage_pending:(fun context staging _pending -> stage_twice context staging)
      ~plan_staged_binds:(fun _context _staging _observers -> ())
      ~staging:(fun context staging ->
        let check_staging label actual =
          if not (actual == staging) then
            Alcotest.failf "%s received stale staging token" label
        in
        staging_commit_plan
          ~preflight:(fun callback_staging ->
            check_staging "preflight" callback_staging;
            record events "preflight")
          ~commit_bind:(fun callback_staging bind ->
            check_staging "commit_bind" callback_staging;
            record events ("commit_bind:" ^ bind);
            [])
          ~prepare_signal:(fun callback_staging _node ->
            check_staging "prepare_signal" callback_staging)
          ~commit_timer_refresh:(fun _timer -> ())
          ~commit_signal:(fun _node -> ())
          ())
      ~update_necessity:(fun _context -> record events "update_necessity")
      ()
  in
  let rollback =
    Graph.stabilization_rollback_ops
      ~rollback_staging:(fun _context _staging -> [])
      ~mark_observers_failed_without_current:(fun _context _observers -> ())
      ~requeue_pending:(fun _context _pending -> ())
  in
  let finish = Graph.create_stabilization_finish () in
  let result =
    with_graph_lane graph (fun lane ->
        Graph.run_stabilization graph lane ~timer_refresh:None
          (Graph.stabilization_ops
             ~classify_graph_error:(fun _ -> None)
             ~pure ~rollback))
  in
  let hooks =
    with_graph_lane graph (fun lane ->
        Graph.record_stabilization_result finish lane result)
  in
  Pass.result result
    ~pure_ok:(fun ~hooks:_ ~events ~delivering_token:_ ->
      Alcotest.(check (list string)) "hooks" [] hooks;
      Alcotest.(check (list string)) "events" [] events)
    ~graph_error:(fun ~hooks:_ err ->
      Alcotest.failf "unexpected graph error: %s"
        (Format.asprintf "%a" Eta_signal_testable.Error.pp_graph_error err))
    ~defect:(fun ~hooks:_ exn _backtrace ->
      Alcotest.failf "unexpected defect: %s" (Printexc.to_string exn));
  with_graph_lane graph (fun lane ->
      Graph.finish_recorded_stabilization graph lane finish);
  Alcotest.(check (list string))
    "commit events" [ "preflight"; "commit_bind:bind"; "update_necessity" ]
    !events;
  let snapshot = Graph.read_effective graph staged in
  Alcotest.(check (option string)) "committed inner" (Some "next")
    (Bind.inner snapshot);
  Alcotest.(check (option int)) "committed scope" (Some 3)
    (Bind.inner_scope snapshot)

let test_stabilization_observer_plan_uses_collection_order () =
  let events = ref [] in
  let graph =
    Graph.create ~create_scope_context:(fun () -> ())
      ~create_stream_bridge_metrics:(fun () -> ()) ()
  in
  let first = create_observer 1 in
  let inactive = create_observer ~active:false 0 in
  let second = create_observer 2 in
  with_graph_lane graph (fun lane ->
      Graph.add_observer graph lane second;
      Graph.add_observer graph lane inactive;
      Graph.add_observer graph lane first);
  let collection =
    Observer.collection_port
      ~live:(fun cap observer ->
        check_cap cap;
        observer.live)
      ~skip:(fun cap observer ->
        check_cap cap;
        observer.id = 99)
      ~compute:(fun cap observer ->
        check_cap cap;
        record events ("compute:" ^ string_of_int observer.id);
        (observer.id * 10, true))
      ~snapshot:(fun cap live ->
        check_cap cap;
        live.snapshot)
      ~stage_snapshot:(fun cap live snapshot ->
        check_cap cap;
        live.snapshot <- snapshot;
        record events
          ("stage:" ^ Observer.Value.label (Observer.Snapshot.value snapshot)))
      ~equal:(fun _observer -> Int.equal)
      ~make_event:(fun cap observer update ->
        check_cap cap;
        let label = update_label update in
        record events ("event:" ^ string_of_int observer.id ^ ":" ^ label);
        "event:" ^ string_of_int observer.id ^ ":" ^ label)
  in
  let collect_event cap observer =
    Observer.collect_event collection cap observer
  in
  let pure =
    stabilization_pure_ops
      ~release_pending_marks:(fun cap _pending -> check_cap cap)
      ~observer_delivery:(fun cap _staging ->
        check_cap cap;
        let selection =
          Observer.delivery_selection_plan
            ~active:(fun observer -> observer.active)
            ~compare:(fun left right -> Int.compare left.id right.id)
        in
        let event_plan =
          Observer.delivery_event_plan ~collect_event
            ~mark_pending:(fun cap event ->
              check_cap cap;
              record events ("pending:" ^ event))
        in
        Observer.delivery_collection ~selection ~events:event_plan)
      ~stage_pending:(fun cap _staging _pending -> check_cap cap)
      ~plan_staged_binds:(fun cap _staging observers ->
        check_cap cap;
        record events
          ("plan_observers:"
          ^ String.concat ","
              (List.map
                 (fun observer -> string_of_int observer.id)
                 observers)))
      ~staging:(fun cap _staging ->
        check_cap cap;
        staging_commit_plan
          ~preflight:(fun _staging -> record events "preflight")
          ~commit_bind:(fun _staging _bind -> [])
          ~prepare_signal:(fun _staging _node -> ())
          ~commit_timer_refresh:(fun _timer -> ())
          ~commit_signal:(fun _node -> ())
          ())
      ~update_necessity:(fun cap ->
        check_cap cap;
        record events "update_necessity")
      ()
  in
  let rollback =
    Graph.stabilization_rollback_ops
      ~rollback_staging:(fun cap _staging ->
        check_cap cap;
        [])
      ~mark_observers_failed_without_current:(fun cap _observers ->
        check_cap cap)
      ~requeue_pending:(fun cap _pending -> check_cap cap)
  in
  let stabilization_finish = Graph.create_stabilization_finish () in
  let result =
    with_graph_lane graph (fun lane ->
        Graph.run_stabilization graph lane ~timer_refresh:None
          (Graph.stabilization_ops
             ~classify_graph_error:(fun _ -> None)
             ~pure ~rollback))
  in
  let hooks =
    with_graph_lane graph (fun lane ->
        Graph.record_stabilization_result stabilization_finish lane result)
  in
  Pass.result result
    ~pure_ok:(fun ~hooks:_ ~events:delivery_events ~delivering_token:_ ->
      Alcotest.(check (list string)) "hooks" [] hooks;
      Alcotest.(check (list string))
        "delivery events"
        [
          "event:1:initialized:10";
          "event:2:initialized:20";
        ]
        delivery_events;
      Alcotest.(check (list string))
        "events"
        [
          "plan_observers:1,2";
          "compute:1";
          "stage:current";
          "event:1:initialized:10";
          "compute:2";
          "stage:current";
          "event:2:initialized:20";
          "preflight";
          "pending:event:1:initialized:10";
          "pending:event:2:initialized:20";
          "update_necessity";
        ]
        !events;
      with_graph_lane graph (fun lane ->
          Graph.finish_recorded_stabilization graph lane
            stabilization_finish))
    ~graph_error:(fun ~hooks:_ err ->
      Alcotest.failf "unexpected graph error: %s"
        (Format.asprintf "%a" Eta_signal_testable.Error.pp_graph_error err))
    ~defect:(fun ~hooks:_ exn _backtrace ->
      Alcotest.failf "unexpected defect: %s" (Printexc.to_string exn))

let test_timer_demand_plan_owns_live_pruning_and_roots () =
  let graph =
    Graph.create ~create_scope_context:(fun () -> ())
      ~create_stream_bridge_metrics:(fun () -> ()) ()
  in
  let live_root = create_demand_node graph ~timer:"root" () in
  let live_timer = create_demand_node graph ~timer:"leaf" () in
  let live_without_timer = create_demand_node graph () in
  let _stale_timer = create_demand_node graph ~live:false ~timer:"stale" () in
  let demand_id node = Id.signal_int node.demand_id in
  with_graph_lane graph (fun lane ->
      Graph.add_observer graph lane None;
      Graph.add_observer graph lane (Some live_root));
  let demand =
    with_graph_lane graph (fun lane ->
        Graph.timer_demand graph lane demand_timer_source)
  in
  let root_necessary, leaf_necessary, timers =
    Graph.timer_demand_plan demand ~plan:(fun ~is_necessary ~timers ->
        ( is_necessary live_root.demand_id,
          is_necessary live_timer.demand_id,
          timers
          |> List.map (fun (id, timer) -> (Id.signal_int id, timer))
          |> List.sort compare ))
  in
  Alcotest.(check bool) "root necessary" true root_necessary;
  Alcotest.(check bool) "leaf unnecessary" false leaf_necessary;
  Alcotest.(check (list (pair int string)))
    "live timer candidates"
    [ (demand_id live_root, "root"); (demand_id live_timer, "leaf") ]
    timers;
  let remaining_live_ids =
    with_graph_lane graph (fun lane ->
        Graph.live_nodes graph lane demand_live_registry)
    |> List.map (fun node -> Id.signal_int node.demand_id)
    |> List.sort Int.compare
  in
  Alcotest.(check (list int))
    "live registry pruned"
    [ demand_id live_root; demand_id live_timer; demand_id live_without_timer ]
    remaining_live_ids

let test_collect_reachable_bind_nodes_owns_valid_dedup () =
  let graph =
    Graph.create ~create_scope_context:(fun () -> ())
      ~create_stream_bridge_metrics:(fun () -> ()) ()
  in
  let root = create_demand_node graph () in
  let child = create_demand_node graph () in
  let invalid = create_demand_node graph ~live:false () in
  root.demand_children <- [ child; invalid; child ];
  let ids =
    with_graph_lane graph (fun lane ->
        Graph.collect_reachable_bind_nodes graph lane demand_reachable_ops
          ~roots:[ root; child ]
          (Graph.bind_node_selection ~bind:(fun node ->
               Some (Id.signal_int node.demand_id))))
    |> List.sort Int.compare
  in
  Alcotest.(check (list int))
    "valid deduplicated reachable ids"
    [ Id.signal_int root.demand_id; Id.signal_int child.demand_id ]
    ids

let test_post_commit_necessary_timers_uses_reachability () =
  let graph =
    Graph.create ~create_scope_context:(fun () -> ())
      ~create_stream_bridge_metrics:(fun () -> ()) ()
  in
  let root = create_demand_node graph ~timer:"root" () in
  let reachable_leaf = create_demand_node graph ~timer:"reachable" () in
  let invalid_leaf = create_demand_node graph ~live:false ~timer:"invalid" () in
  let live_but_unnecessary = create_demand_node graph ~timer:"unnecessary" () in
  root.demand_children <- [ reachable_leaf; invalid_leaf ];
  let demand_id node = Id.signal_int node.demand_id in
  with_graph_lane graph (fun lane ->
      Graph.add_observer graph lane None;
      Graph.add_observer graph lane (Some root));
  let timers =
    with_graph_lane graph (fun lane ->
        Graph.post_commit_necessary_timers graph lane demand_timer_source)
    |> Hashtbl.to_seq
    |> List.of_seq
    |> List.map (fun (id, timer) -> (Id.signal_int id, timer))
    |> List.sort compare
  in
  Alcotest.(check (list (pair int string)))
    "necessary timers"
    [ (demand_id root, "root"); (demand_id reachable_leaf, "reachable") ]
    timers;
  let remaining_live_ids =
    with_graph_lane graph (fun lane ->
        Graph.live_nodes graph lane demand_live_registry)
    |> List.map (fun node -> Id.signal_int node.demand_id)
    |> List.sort Int.compare
  in
  Alcotest.(check (list int))
    "live registry pruned"
    [ demand_id root; demand_id reachable_leaf; demand_id live_but_unnecessary ]
    remaining_live_ids

let test_timer_refresh_token_owned_by_graph () =
  let graph =
    Graph.create ~create_scope_context:(fun () -> ())
      ~create_stream_bridge_metrics:(fun () -> ()) ()
  in
  Alcotest.(check (result int reject))
    "first token" (Ok 0)
    (with_graph_lane graph (fun lane ->
         Graph.next_timer_refresh_token graph lane));
  Alcotest.(check (result int reject))
    "second token" (Ok 1)
    (with_graph_lane graph (fun lane ->
         Graph.next_timer_refresh_token graph lane));
  with_graph_lane graph (fun lane ->
      Graph.set_next_timer_refresh_token graph lane max_int);
  match
    with_graph_lane graph (fun lane ->
        Graph.next_timer_refresh_token graph lane)
  with
  | Error (`Counter_overflow name) when String.equal name "timer refresh token" ->
      ()
  | Error err ->
      Alcotest.failf "unexpected graph error: %s"
        (Format.asprintf "%a" Eta_signal_testable.Error.pp_graph_error err)
  | Ok token -> Alcotest.failf "expected overflow, got token %d" token

let test_staged_bind_switch_protocol_maps_graph_errors () =
  let events = ref [] in
  let current = Bind.switch ~source_value:0 ~inner:10 ~scope:1 in
  let staged = Bind.switch ~source_value:1 ~inner:20 ~scope:2 in
  let switch =
    Bind.staged_switch ~owner:(Some 99) ~current ~staged:(Some staged)
  in
  let commit_lifecycle =
    Bind.staged_switch_lifecycle
      ~detach_old_inner:(fun owner inner ->
        record events
          ("detach:" ^ string_of_int owner ^ ":" ^ string_of_int inner))
      ~invalidate_scope:(fun scope ->
        record events ("invalidate:" ^ string_of_int scope);
        [ "hook:" ^ string_of_int scope ])
      ~attach_new_inner:(fun owner inner ->
        record events
          ("attach:" ^ string_of_int owner ^ ":" ^ string_of_int inner))
  in
  let hooks =
    match
      Graph.commit_staged_bind_switch switch commit_lifecycle
    with
    | Ok hooks -> hooks
    | Error err ->
        Alcotest.failf "unexpected graph error: %s"
          (Format.asprintf "%a" Eta_signal_testable.Error.pp_graph_error err)
  in
  Alcotest.(check (list string))
    "commit events"
    [ "detach:99:10"; "invalidate:1"; "attach:99:20" ]
    !events;
  Alcotest.(check (list string)) "commit hooks" [ "hook:1" ] hooks;
  let rollback_lifecycle =
    Bind.staged_switch_lifecycle
      ~detach_old_inner:(fun _ _ ->
        Alcotest.fail "rollback should not detach")
      ~invalidate_scope:(fun scope ->
        record events ("rollback:" ^ string_of_int scope);
        [ "rollback-hook:" ^ string_of_int scope ])
      ~attach_new_inner:(fun _ _ ->
        Alcotest.fail "rollback should not attach")
  in
  let rollback_hooks =
    match
      Graph.rollback_staged_bind_switch ~staged:(Some staged)
        rollback_lifecycle
    with
    | Ok hooks -> hooks
    | Error err ->
        Alcotest.failf "unexpected graph error: %s"
          (Format.asprintf "%a" Eta_signal_testable.Error.pp_graph_error err)
  in
  Alcotest.(check (list string))
    "rollback hooks" [ "rollback-hook:2" ] rollback_hooks;
  ()

let () =
  Alcotest.run "eta_signal_graph"
    [
      ( "node lifecycle",
        [
          Alcotest.test_case "context owns creation" `Quick
            test_create_live_node_owns_lifecycle_context;
          Alcotest.test_case "context owns invalidation" `Quick
            test_invalidate_live_node_owns_lifecycle_order;
        ] );
      ( "compute dispatch",
        [
          Alcotest.test_case "cached dispatch" `Quick
            test_compute_cached_owns_cache_and_cycle_dispatch;
          Alcotest.test_case "generation ownership" `Quick
            test_generation_owned_by_graph;
          Alcotest.test_case "delivery bookkeeping ownership" `Quick
            test_stabilization_delivery_ops_own_counter_and_finish;
          Alcotest.test_case "computed staging token" `Quick
            test_computed_nodes_are_staging_scoped;
        ] );
      ( "bind switch",
        [
          Alcotest.test_case "graph owns transaction staging" `Quick
            test_stage_bind_switch_owns_transaction_staging;
          Alcotest.test_case "graph error boundary" `Quick
            test_staged_bind_switch_protocol_maps_graph_errors;
        ] );
      ( "observer delivery",
        [
          Alcotest.test_case "lane-scoped registry traversal" `Quick
            test_observer_registry_traversal_uses_lane;
          Alcotest.test_case "sorted collection" `Quick
            test_stabilization_observer_plan_uses_collection_order;
        ] );
      ( "timer demand",
        [
          Alcotest.test_case "reachable selection" `Quick
            test_collect_reachable_bind_nodes_owns_valid_dedup;
          Alcotest.test_case "plan bridge" `Quick
            test_timer_demand_plan_owns_live_pruning_and_roots;
          Alcotest.test_case "post-commit reachability" `Quick
            test_post_commit_necessary_timers_uses_reachability;
          Alcotest.test_case "refresh token ownership" `Quick
            test_timer_refresh_token_owned_by_graph;
        ] );
    ]
