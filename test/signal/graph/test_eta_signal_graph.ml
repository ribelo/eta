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
          Graph.observer_delivery_plan graph
            {
              Graph.observer_active = (fun observer -> observer.active);
              observer_compare =
                (fun left right -> Int.compare left.id right.id);
              observer_collect_event = collect_event;
              observer_mark_pending =
                (fun cap event ->
                  check_cap cap;
                  record events ("pending:" ^ event));
            });
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
          Graph.commit_staging graph staging
            {
              Graph.staging_commit_preflight =
                (fun () -> record events "preflight");
              staging_commit_bind = (fun _bind -> []);
              staging_commit_prepare_signal = (fun _node -> ());
              staging_commit_transaction =
                (fun () -> commit_transaction graph);
              staging_commit_timer_refresh = (fun _timer -> ());
              staging_commit_signal = (fun _node -> ());
              staging_commit_advance_snapshot = (fun value -> value + 1);
            });
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
