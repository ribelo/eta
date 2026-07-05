module Graph = Eta_signal_testable.Graph
module Id = Eta_signal_testable.Id
module Observer = Eta_signal_testable.Observer_core
module Pass = Eta_signal_testable.Stabilization_pass

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

let capability = "graph-lane"

let record events event =
  events := !events @ [ event ]

let check_cap cap =
  Alcotest.(check string) "capability" capability cap

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

let update_label = function
  | Observer.Update.Initialized value ->
      "initialized:" ^ string_of_int value
  | Observer.Update.Changed { old_value; new_value } ->
      "changed:" ^ string_of_int old_value ^ "->"
      ^ string_of_int new_value

let commit_transaction graph =
  match Graph.commit_transaction graph with
  | Ok () -> ()
  | Error err ->
      Alcotest.failf "unexpected graph error: %s"
        (Format.asprintf "%a" Eta_signal_testable.Error.pp_graph_error err)

let scoped_graph scope_context =
  Graph.create ~create_scope_context:(fun () -> scope_context)
    ~create_stream_bridge_metrics:(fun () -> ()) ()

let test_scope_ops =
  {
    Graph.scope_current = (fun context -> context.current_scope);
    scope_require_valid_current =
      (fun context ->
        match context.current_scope with
        | Some scope -> Ok scope
        | None -> Error `Ambiguous_scope);
    scope_with_current =
      (fun context scope f ->
        let previous = context.current_scope in
        context.current_scope <- Some scope;
        Fun.protect ~finally:(fun () -> context.current_scope <- previous) f);
  }

let live_nodes_from_cells _keep cells = (cells, cells)

let compute_ops =
  {
    Graph.compute_node = (fun node -> node);
    compute_pack = (fun node -> node);
    compute_seen_generation = (fun node -> node.compute_seen_generation);
    compute_set_seen_generation =
      (fun node generation -> node.compute_seen_generation <- generation);
    compute_changed_seen = (fun node -> node.compute_changed_seen);
    compute_set_changed_seen =
      (fun node changed -> node.compute_changed_seen <- changed);
    compute_computing = (fun node -> node.compute_computing);
    compute_set_computing =
      (fun node computing -> node.compute_computing <- computing);
    compute_computed_generation =
      (fun node -> node.compute_computed_generation);
    compute_set_computed_generation =
      (fun node generation -> node.compute_computed_generation <- generation);
  }

let invalidating_node ?kind_scope id =
  {
    invalid_id = id;
    invalid_valid = true;
    invalid_dependencies = [];
    invalid_dependents = [];
    invalid_kind_scope = kind_scope;
  }

let invalidating_edge_ops events =
  {
    Graph.edge_id = (fun node -> node.invalid_id);
    edge_equal_id = Int.equal;
    edge_dependencies = (fun node -> node.invalid_dependencies);
    edge_set_dependencies =
      (fun node dependencies ->
        record events
          ("dependencies:" ^ string_of_int node.invalid_id ^ ":"
         ^ string_of_int (List.length dependencies));
        node.invalid_dependencies <- dependencies);
    edge_dependents = (fun node -> node.invalid_dependents);
    edge_set_dependents =
      (fun node dependents ->
        record events
          ("dependents:" ^ string_of_int node.invalid_id ^ ":"
         ^ string_of_int (List.length dependents));
        node.invalid_dependents <- dependents);
  }

let test_create_live_node_owns_lifecycle_context () =
  let events = ref [] in
  let scope = { scope_id = 42; scope_nodes = [] } in
  let graph = scoped_graph { current_scope = Some scope } in
  let lifecycle =
    {
      Graph.node_validate_dependency =
        (fun dependency ->
          record events ("validate:" ^ string_of_int dependency));
      node_create =
        (fun ~id ~scope ->
          let id = Id.signal_int id in
          let scope_label =
            match scope with
            | Some scope -> "scope:" ^ string_of_int scope.scope_id
            | None -> "no_scope"
          in
          record events
            ("create:" ^ string_of_int id ^ ":" ^ scope_label);
          { node_id = id; node_scope = scope; node_dependencies = [] });
      node_attach_dependency =
        (fun ~parent ~child ->
          record events
            ("attach:" ^ string_of_int parent.node_id ^ "<-"
           ^ string_of_int child);
          parent.node_dependencies <- parent.node_dependencies @ [ child ]);
      node_add_to_scope =
        (fun scope node ->
          record events
            ("scope:" ^ string_of_int scope.scope_id ^ ":"
           ^ string_of_int node.node_id);
          scope.scope_nodes <- scope.scope_nodes @ [ node.node_id ]);
      node_pack =
        (fun node ->
          record events ("pack:" ^ string_of_int node.node_id);
          node);
      node_create_weak =
        (fun node ->
          record events ("weak:" ^ string_of_int node.node_id);
          node);
    }
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
    Graph.live_nodes graph ~collect_live_nodes:live_nodes_from_cells
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
    {
      Graph.invalidation_valid = (fun node -> node.invalid_valid);
      invalidation_set_invalid =
        (fun node ->
          record events ("invalid:" ^ string_of_int node.invalid_id);
          node.invalid_valid <- false);
      invalidation_timer_hooks =
        (fun node ->
          record events ("timer:" ^ string_of_int node.invalid_id);
          [ "timer-hook:" ^ string_of_int node.invalid_id ]);
      invalidation_tombstone =
        (fun node ->
          record events ("tombstone:" ^ string_of_int node.invalid_id);
          {
            dead_id = Id.signal node.invalid_id;
            dead_label = "dead:" ^ string_of_int node.invalid_id;
          });
      invalidation_tombstone_id = (fun dead -> dead.dead_id);
      invalidation_observer_hooks =
        (fun node ->
          record events ("observer:" ^ string_of_int node.invalid_id);
          [ "observer-hook:" ^ string_of_int node.invalid_id ]);
      invalidation_kind_hooks =
        (fun ~invalidate_scope node ->
          record events ("kind:" ^ string_of_int node.invalid_id);
          match node.invalid_kind_scope with
          | None -> []
          | Some scope -> invalidate_scope ~prune:false scope);
    }
  in
  let invalidate_scope ?(prune = true) scope =
    record events
      ("scope:" ^ string_of_int scope ^ ":prune:" ^ string_of_bool prune);
    [ "scope-hook:" ^ string_of_int scope ]
  in
  let hooks =
    Graph.invalidate_live_node graph (invalidating_edge_ops events)
      lifecycle ~invalidate_scope root
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
  Alcotest.(check int) "dead count" 2 (Graph.dead_node_count graph);
  Alcotest.(check (list string))
    "dead nodes"
    [ "dead:2"; "dead:1" ]
    (Graph.map_dead_nodes graph ~f:(fun dead -> dead.dead_label))

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
  Graph.set_generation graph 1;
  Alcotest.(check (pair int bool))
    "first compute" (10, true)
    (Graph.compute_cached graph compute_ops node ~current ~cycle ~compute);
  Alcotest.(check int) "seen generation" 1 node.compute_seen_generation;
  Alcotest.(check bool) "changed seen" true node.compute_changed_seen;
  Alcotest.(check bool) "guard cleared" false node.compute_computing;
  Alcotest.(check (pair int bool))
    "cached compute" (10, true)
    (Graph.compute_cached graph compute_ops node ~current ~cycle ~compute);
  node.compute_computing <- true;
  Graph.set_generation graph 2;
  Alcotest.(check (pair int bool))
    "cycle result" (10, false)
    (Graph.compute_cached graph compute_ops node ~current ~cycle ~compute);
  Alcotest.(check int)
    "cycle does not publish generation" 1 node.compute_seen_generation;
  Alcotest.(check bool)
    "existing guard remains owned by caller" true node.compute_computing;
  Alcotest.(check (list string))
    "events"
    [ "compute:1"; "current:10"; "cycle:1" ]
    !events

let test_observer_delivery_plan_owns_sorted_collection () =
  let events = ref [] in
  let graph =
    Graph.create ~create_scope_context:(fun () -> ())
      ~create_stream_bridge_metrics:(fun () -> ()) ()
  in
  let first = create_observer 1 in
  let inactive = create_observer ~active:false 0 in
  let second = create_observer 2 in
  Graph.add_observer graph second;
  Graph.add_observer graph inactive;
  Graph.add_observer graph first;
  let collection =
    {
      Observer.collection_live =
        (fun cap observer ->
          check_cap cap;
          observer.live);
      collection_skip =
        (fun cap observer ->
          check_cap cap;
          observer.id = 99);
      collection_compute =
        (fun cap observer ->
          check_cap cap;
          record events ("compute:" ^ string_of_int observer.id);
          (observer.id * 10, true));
      collection_snapshot =
        (fun cap live ->
          check_cap cap;
          live.snapshot);
      collection_stage_snapshot =
        (fun cap live snapshot ->
          check_cap cap;
          live.snapshot <- snapshot;
          record events
            ("stage:"
            ^ Observer.Value.label (Observer.Snapshot.value snapshot)));
      collection_equal = (fun _observer -> Int.equal);
      collection_make_event =
        (fun cap observer update ->
          check_cap cap;
          let label = update_label update in
          record events
            ("event:" ^ string_of_int observer.id ^ ":" ^ label);
          "event:" ^ string_of_int observer.id ^ ":" ^ label);
    }
  in
  let collect_event cap observer =
    Observer.collect_event collection cap observer
  in
  let pure =
    {
      Pass.advance_generation = (fun context ->
        check_cap (Pass.pure_capability context));
      begin_staging =
        (fun context ->
          check_cap (Pass.pure_capability context);
          Graph.begin_staging graph ~timer_refresh:None);
      drain_pending =
        (fun context ->
          check_cap (Pass.pure_capability context);
          []);
      release_pending_marks =
        (fun context _pending ->
          check_cap (Pass.pure_capability context));
      observer_plan =
        (fun context ->
          check_cap (Pass.pure_capability context);
          let delivery =
            Graph.observer_delivery_context
              ~active:(fun observer -> observer.active)
              ~compare:(fun left right -> Int.compare left.id right.id)
              ~collect_event
              ~mark_pending:(fun cap event ->
                check_cap cap;
                record events ("pending:" ^ event))
          in
          Graph.observer_delivery_plan graph delivery);
      stage_pending =
        (fun context _pending ->
          check_cap (Pass.pure_capability context));
      plan_staged_binds =
        (fun context observers ->
          check_cap (Pass.pure_capability context);
          record events
            ("plan_observers:"
            ^ String.concat ","
                (List.map
                   (fun observer -> string_of_int observer.id)
                   observers)));
      commit_staging =
        (fun context staging ->
          check_cap (Pass.pure_capability context);
          let commit_context =
            Graph.staging_commit_context
              ~preflight:(fun () -> record events "preflight")
              ~commit_bind:(fun _bind -> [])
              ~prepare_signal:(fun _node -> ())
              ~commit_transaction:(fun () -> commit_transaction graph)
              ~commit_timer_refresh:(fun _timer -> ())
              ~commit_signal:(fun _node -> ())
              ~advance_snapshot:(fun value -> value + 1)
          in
          Graph.commit_staging graph staging commit_context);
      update_necessity =
        (fun context ->
          check_cap (Pass.pure_capability context);
          record events "update_necessity");
    }
  in
  let rollback =
    {
      Pass.rollback_staging =
        (fun context _staging ->
          check_cap (Pass.rollback_capability context);
          []);
      mark_observers_failed_without_current =
        (fun context _observers ->
          check_cap (Pass.rollback_capability context));
      requeue_pending =
        (fun context _pending ->
          check_cap (Pass.rollback_capability context));
    }
  in
  match
    Graph.run_stabilization graph capability
      {
        Graph.errors =
          {
            Pass.reentrant_stabilization = `Reentrant_stabilization;
            classify_graph_error = (fun _ -> None);
          };
        pure;
        rollback;
      }
  with
  | Pass.Pure_ok (hooks, delivery_events, delivering_token) ->
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
      Graph.finish_stabilization graph delivering_token
  | Pass.Pure_graph_error (_hooks, err) ->
      Alcotest.failf "unexpected graph error: %s"
        (Format.asprintf "%a" Eta_signal_testable.Error.pp_graph_error err)
  | Pass.Pure_defect (_hooks, exn, _backtrace) ->
      Alcotest.failf "unexpected defect: %s" (Printexc.to_string exn)

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
        ] );
      ( "observer delivery",
        [
          Alcotest.test_case "sorted collection" `Quick
            test_observer_delivery_plan_owns_sorted_collection;
        ] );
    ]
