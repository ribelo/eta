module S = Eta_signal_stabilization
module Pass = Eta_signal_stabilization_pass

type owner
type 'state token = (owner, 'state) S.token
type 'error stabilization = (owner, 'error) S.t

type test_error = [ `Delivery_failed | `Graph | `Reentrant_stabilization ]

exception Graph_failure

let record events event = events := !events @ [ event ]

let run_effect eff =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let runtime =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ()
  in
  Eta.Runtime.run runtime eff

let expect_effect_ok label eff =
  match run_effect eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error _ -> Alcotest.failf "%s: expected Ok" label

let expect_effect_fail label eff =
  match run_effect eff with
  | Eta.Exit.Error (Eta.Cause.Fail `Delivery_failed) -> ()
  | Eta.Exit.Error _ -> Alcotest.failf "%s: expected Delivery_failed" label
  | Eta.Exit.Ok _ -> Alcotest.failf "%s: expected failure" label

let ops ?(stage_pending = fun _ -> ())
    ?(commit_staging = fun _ -> [ "hook" ]) state events =
  let check_staging staging =
    Alcotest.(check string) "staging token" "staging" staging
  in
  {
    Pass.errors =
      {
        reentrant_stabilization = `Reentrant_stabilization;
        classify_graph_error =
          (function
          | Graph_failure -> Some `Graph
          | _ -> None);
      };
    pure =
      {
        advance_generation = (fun () -> record events "advance_generation");
        begin_staging =
          (fun () ->
            record events "begin_staging";
            "staging");
        drain_pending =
          (fun () ->
            record events "drain_pending";
            [ "pending" ]);
        release_pending_marks =
          (fun pending ->
            record events
              ("release_pending_marks:" ^ String.concat "," pending));
        active_observers =
          (fun () ->
            record events "active_observers";
            [ "observer" ]);
        stage_pending =
          (fun pending ->
            record events ("stage_pending:" ^ String.concat "," pending);
            stage_pending pending);
        plan_staged_binds =
          (fun observers ->
            record events ("plan_staged_binds:" ^ String.concat "," observers));
        sort_delivery_observers =
          (fun observers ->
            record events
              ("sort_delivery_observers:" ^ String.concat "," observers);
            observers);
        collect_events =
          (fun observers ->
            record events ("collect_events:" ^ String.concat "," observers);
            [ "event" ]);
        commit_staging =
          (fun staging ->
            check_staging staging;
            record events "commit_staging";
            let hooks = commit_staging staging in
            (match S.commit_transaction state with
            | Ok () -> ()
            | Error _ -> Alcotest.fail "unexpected transaction commit failure");
            hooks);
        mark_events_pending =
          (fun events_to_mark ->
            record events
              ("mark_events_pending:" ^ String.concat "," events_to_mark));
        update_necessity = (fun () -> record events "update_necessity");
      };
    rollback =
      {
        rollback_staging =
          (fun staging ->
            check_staging staging;
            record events "rollback_staging";
            S.rollback_transaction state;
            [ "rollback-hook" ]);
        mark_observers_failed_without_current =
          (fun observers ->
            record events
              ("mark_observers_failed_without_current:" ^ String.concat ","
                 observers));
        requeue_pending =
          (fun pending ->
            record events ("requeue_pending:" ^ String.concat "," pending));
      };
    timer_refresh =
      {
        clear_active_timer_refresh =
          (fun () -> record events "clear_timer_refresh");
      };
  }

let test_success_runs_pure_pass_in_order () =
  let events = ref [] in
  let state : test_error stabilization = S.create () in
  match Pass.run state (ops state events) with
  | Pass.Pure_ok (hooks, pass_events, delivering) ->
      Alcotest.(check (list string))
        "callback order"
        [
          "advance_generation";
          "begin_staging";
          "drain_pending";
          "release_pending_marks:pending";
          "active_observers";
          "stage_pending:pending";
          "plan_staged_binds:observer";
          "sort_delivery_observers:observer";
          "collect_events:observer";
          "commit_staging";
          "mark_events_pending:event";
          "update_necessity";
          "clear_timer_refresh";
        ]
        !events;
      Alcotest.(check (list string)) "hooks" [ "hook" ] hooks;
      Alcotest.(check (list string)) "events" [ "event" ] pass_events;
      Alcotest.(check bool) "delivering" true
        (match S.state state with
        | S.Delivering -> true
        | S.Idle | S.Pure | S.Committed -> false);
      ignore (S.finish_delivering state delivering : S.idle token)
  | Pass.Pure_graph_error _ -> Alcotest.fail "unexpected graph error"
  | Pass.Pure_defect _ -> Alcotest.fail "unexpected defect"

let test_graph_error_rolls_back_in_order () =
  let events = ref [] in
  let state : test_error stabilization = S.create () in
  match
    Pass.run state
      (ops state events ~stage_pending:(fun _ -> raise Graph_failure))
  with
  | Pass.Pure_graph_error (hooks, `Graph) ->
      Alcotest.(check (list string))
        "callback order"
        [
          "advance_generation";
          "begin_staging";
          "drain_pending";
          "release_pending_marks:pending";
          "active_observers";
          "stage_pending:pending";
          "rollback_staging";
          "mark_observers_failed_without_current:observer";
          "requeue_pending:pending";
          "clear_timer_refresh";
        ]
        !events;
      Alcotest.(check (list string)) "hooks" [ "rollback-hook" ] hooks;
      Alcotest.(check bool) "idle" true
        (match S.state state with
        | S.Idle -> true
        | S.Pure | S.Committed | S.Delivering -> false)
  | Pass.Pure_graph_error (_, `Reentrant_stabilization) ->
      Alcotest.fail "unexpected reentrant error"
  | Pass.Pure_graph_error (_, `Delivery_failed) ->
      Alcotest.fail "unexpected delivery error"
  | Pass.Pure_ok _ -> Alcotest.fail "unexpected success"
  | Pass.Pure_defect _ -> Alcotest.fail "unexpected defect"

let test_defect_rolls_back_in_order () =
  let events = ref [] in
  let state : test_error stabilization = S.create () in
  match
    Pass.run state
      (ops state events ~commit_staging:(fun _ -> failwith "boom"))
  with
  | Pass.Pure_defect (hooks, _, _) ->
      Alcotest.(check (list string))
        "callback order"
        [
          "advance_generation";
          "begin_staging";
          "drain_pending";
          "release_pending_marks:pending";
          "active_observers";
          "stage_pending:pending";
          "plan_staged_binds:observer";
          "sort_delivery_observers:observer";
          "collect_events:observer";
          "commit_staging";
          "rollback_staging";
          "mark_observers_failed_without_current:observer";
          "requeue_pending:pending";
          "clear_timer_refresh";
        ]
        !events;
      Alcotest.(check (list string)) "hooks" [ "rollback-hook" ] hooks;
      Alcotest.(check bool) "idle" true
        (match S.state state with
        | S.Idle -> true
        | S.Pure | S.Committed | S.Delivering -> false)
  | Pass.Pure_ok _ -> Alcotest.fail "unexpected success"
  | Pass.Pure_graph_error _ -> Alcotest.fail "unexpected graph error"

let test_reentrant_begin_is_graph_error_without_callbacks () =
  let events = ref [] in
  let state : test_error stabilization = S.create () in
  let pure =
    match S.begin_pure state with
    | Ok pure -> pure
    | Error `Reentrant_stabilization -> Alcotest.fail "expected first begin"
  in
  (match Pass.run state (ops state events) with
  | Pass.Pure_graph_error (hooks, `Reentrant_stabilization) ->
      Alcotest.(check (list string)) "no hooks" [] hooks;
      Alcotest.(check (list string)) "no callbacks" [] !events
  | Pass.Pure_graph_error (_, `Graph) ->
      Alcotest.fail "unexpected graph error"
  | Pass.Pure_graph_error (_, `Delivery_failed) ->
      Alcotest.fail "unexpected delivery error"
  | Pass.Pure_ok _ -> Alcotest.fail "unexpected success"
  | Pass.Pure_defect _ -> Alcotest.fail "unexpected defect");
  S.rollback_transaction state;
  ignore (S.rollback_to_idle state pure : S.idle token)

let delivery_ops ?(run_events = fun _events -> Eta.Effect.unit) events =
  {
    Pass.run_pending_cleanup =
      (fun () -> Eta.Effect.sync (fun () -> record events "cleanup"));
    run_events =
      (fun delivery_events ->
        Eta.Effect.sync (fun () ->
            record events
              ("events:" ^ String.concat "," delivery_events))
        |> Eta.Effect.bind (fun () -> run_events delivery_events));
    mark_complete =
      (fun () -> Eta.Effect.sync (fun () -> record events "complete"));
    finish = (fun () -> Eta.Effect.sync (fun () -> record events "finish"));
  }

let test_delivery_success_brackets_cleanup_and_finish () =
  let events = ref [] in
  expect_effect_ok "delivery success"
    (Pass.deliver (delivery_ops events) [ "first"; "second" ]);
  Alcotest.(check (list string))
    "callback order"
    [
      "cleanup";
      "events:first,second";
      "complete";
      "cleanup";
      "finish";
    ]
    !events

let test_delivery_failure_runs_final_cleanup_and_finish () =
  let events = ref [] in
  expect_effect_fail "delivery failure"
    (Pass.deliver
       (delivery_ops events ~run_events:(fun _ ->
            Eta.Effect.fail `Delivery_failed))
       [ "event" ]);
  Alcotest.(check (list string))
    "callback order"
    [ "cleanup"; "events:event"; "cleanup"; "finish" ]
    !events

let () =
  Alcotest.run "eta_signal_stabilization_pass"
    [
      ( "stabilization_pass",
        [
          Alcotest.test_case "success callback order" `Quick
            test_success_runs_pure_pass_in_order;
          Alcotest.test_case "graph error rollback order" `Quick
            test_graph_error_rolls_back_in_order;
          Alcotest.test_case "defect rollback order" `Quick
            test_defect_rolls_back_in_order;
          Alcotest.test_case "reentrant begin" `Quick
            test_reentrant_begin_is_graph_error_without_callbacks;
          Alcotest.test_case "delivery success bracketing" `Quick
            test_delivery_success_brackets_cleanup_and_finish;
          Alcotest.test_case "delivery failure bracketing" `Quick
            test_delivery_failure_runs_final_cleanup_and_finish;
        ] );
    ]
