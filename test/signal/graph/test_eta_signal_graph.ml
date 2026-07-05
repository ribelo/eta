module Graph = Eta_signal_testable.Graph
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
            ~preflight:(fun () -> record events "preflight")
            ~commit_bind:(fun _bind -> [])
            ~prepare_signal:(fun _node -> ())
            ~commit_transaction:(fun () -> commit_transaction graph)
            ~commit_timer_refresh:(fun _timer -> ())
            ~commit_signal:(fun _node -> ())
            ~advance_snapshot:(fun value -> value + 1));
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
      ( "observer delivery",
        [
          Alcotest.test_case "sorted collection" `Quick
            test_observer_delivery_plan_owns_sorted_collection;
        ] );
    ]
