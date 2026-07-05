module S = Eta_signal_stabilization
module Pass = Eta_signal_stabilization_pass

type owner
type 'state token = (owner, 'state) S.token
type 'error stabilization = (owner, 'error) S.t

type test_error = [ `Delivery_failed | `Graph | `Reentrant_stabilization ]

exception Graph_failure
exception Defect_failure

let capability = "graph-lane"
let record events event = events := !events @ [ event ]

let check_cap cap =
  Alcotest.(check string) "capability" capability cap

let check_pure_context context =
  check_cap (Pass.pure_capability context)

let check_rollback_context context =
  check_cap (Pass.rollback_capability context)

let check_timer_refresh_context context =
  check_cap (Pass.timer_refresh_capability context)

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

let expect_pure_ok result f =
  Pass.result result ~pure_ok:f
    ~graph_error:(fun ~hooks:_ _ -> Alcotest.fail "unexpected graph error")
    ~defect:(fun ~hooks:_ exn _ ->
      Alcotest.failf "unexpected defect: %s" (Printexc.to_string exn))

let expect_graph_error result f =
  Pass.result result
    ~pure_ok:(fun ~hooks:_ ~events:_ ~delivering_token:_ ->
      Alcotest.fail "unexpected success")
    ~graph_error:f
    ~defect:(fun ~hooks:_ exn _ ->
      Alcotest.failf "unexpected defect: %s" (Printexc.to_string exn))

let expect_defect result f =
  Pass.result result
    ~pure_ok:(fun ~hooks:_ ~events:_ ~delivering_token:_ ->
      Alcotest.fail "unexpected success")
    ~graph_error:(fun ~hooks:_ _ -> Alcotest.fail "unexpected graph error")
    ~defect:f

type failure_slot =
  | Advance_generation
  | Begin_staging
  | Drain_pending
  | Release_pending_marks
  | Observer_plan
  | Stage_pending
  | Plan_staged_binds
  | Collect_events
  | Commit_staging

type failure_kind =
  | Graph_error
  | Defect

let failure_slot_name = function
  | Advance_generation -> "advance_generation"
  | Begin_staging -> "begin_staging"
  | Drain_pending -> "drain_pending"
  | Release_pending_marks -> "release_pending_marks"
  | Observer_plan -> "observer_plan"
  | Stage_pending -> "stage_pending"
  | Plan_staged_binds -> "plan_staged_binds"
  | Collect_events -> "collect_events"
  | Commit_staging -> "commit_staging"

let failure_slot_rank = function
  | Advance_generation -> 0
  | Begin_staging -> 1
  | Drain_pending -> 2
  | Release_pending_marks -> 3
  | Observer_plan -> 4
  | Stage_pending -> 5
  | Plan_staged_binds -> 6
  | Collect_events -> 7
  | Commit_staging -> 8

let failure_slots =
  [
    Advance_generation;
    Begin_staging;
    Drain_pending;
    Release_pending_marks;
    Observer_plan;
    Stage_pending;
    Plan_staged_binds;
    Collect_events;
    Commit_staging;
  ]

let pure_event = function
  | Advance_generation -> "advance_generation"
  | Begin_staging -> "begin_staging"
  | Drain_pending -> "drain_pending"
  | Release_pending_marks -> "release_pending_marks:pending"
  | Observer_plan -> "observer_plan"
  | Stage_pending -> "stage_pending:pending"
  | Plan_staged_binds -> "plan_staged_binds:observer"
  | Collect_events -> "collect_events:observer"
  | Commit_staging -> "commit_staging"

let events_through_slot slot =
  failure_slots
  |> List.filter (fun candidate ->
         failure_slot_rank candidate <= failure_slot_rank slot)
  |> List.map pure_event

let rollback_events slot =
  match slot with
  | Advance_generation | Begin_staging -> [ "clear_timer_refresh" ]
  | Drain_pending ->
      [
        "rollback_staging";
        "mark_observers_failed_without_current:";
        "requeue_pending:";
        "clear_timer_refresh";
      ]
  | Release_pending_marks | Observer_plan ->
      [
        "rollback_staging";
        "mark_observers_failed_without_current:";
        "requeue_pending:pending";
        "clear_timer_refresh";
      ]
  | Stage_pending | Plan_staged_binds | Collect_events | Commit_staging ->
      [
        "rollback_staging";
        "mark_observers_failed_without_current:observer";
        "requeue_pending:pending";
        "clear_timer_refresh";
      ]

let expected_failure_events slot = events_through_slot slot @ rollback_events slot

let expected_failure_hooks = function
  | Advance_generation | Begin_staging -> []
  | Drain_pending | Release_pending_marks | Observer_plan | Stage_pending
  | Plan_staged_binds | Collect_events | Commit_staging ->
      [ "rollback-hook" ]

let maybe_fail fail_at failure_kind slot =
  match fail_at with
  | Some candidate when candidate = slot -> (
      match failure_kind with
      | Graph_error -> raise Graph_failure
      | Defect -> raise Defect_failure)
  | Some _ | None -> ()

let ops ?(stage_pending = fun _ -> ())
    ?(commit_staging = fun _ -> [ "hook" ]) ?fail_at
    ?(failure_kind = Graph_error) state events =
  let check_staging staging =
    Alcotest.(check string) "staging token" "staging" staging
  in
  let errors =
    Pass.errors ~reentrant_stabilization:`Reentrant_stabilization
      ~classify_graph_error:(function
        | Graph_failure -> Some `Graph
        | _ -> None)
  in
  let pure =
    Pass.pure_ops
      ~advance_generation:(fun context ->
        check_pure_context context;
        record events "advance_generation";
        maybe_fail fail_at failure_kind Advance_generation)
      ~begin_staging:(fun context ->
        check_pure_context context;
        record events "begin_staging";
        maybe_fail fail_at failure_kind Begin_staging;
        "staging")
      ~drain_pending:(fun context ->
        check_pure_context context;
        record events "drain_pending";
        maybe_fail fail_at failure_kind Drain_pending;
        [ "pending" ])
      ~release_pending_marks:(fun context pending ->
        check_pure_context context;
        record events ("release_pending_marks:" ^ String.concat "," pending);
        maybe_fail fail_at failure_kind Release_pending_marks)
      ~observer_plan:(fun context ->
        check_pure_context context;
        record events "observer_plan";
        maybe_fail fail_at failure_kind Observer_plan;
        Pass.observer_plan ~observers:[ "observer" ]
          ~collect_events:(fun context observers ->
            check_pure_context context;
            record events ("collect_events:" ^ String.concat "," observers);
            maybe_fail fail_at failure_kind Collect_events;
            [ "event" ])
          ~mark_events_pending:(fun context events_to_mark ->
            check_pure_context context;
            record events
              ("mark_events_pending:" ^ String.concat "," events_to_mark)))
      ~stage_pending:(fun context pending ->
        check_pure_context context;
        record events ("stage_pending:" ^ String.concat "," pending);
        maybe_fail fail_at failure_kind Stage_pending;
        stage_pending pending)
      ~plan_staged_binds:(fun context observers ->
        check_pure_context context;
        record events ("plan_staged_binds:" ^ String.concat "," observers);
        maybe_fail fail_at failure_kind Plan_staged_binds)
      ~commit_staging:(fun context staging ->
        check_pure_context context;
        check_staging staging;
        record events "commit_staging";
        maybe_fail fail_at failure_kind Commit_staging;
        let hooks = commit_staging staging in
        (match S.commit_transaction state with
        | Ok () -> ()
        | Error _ -> Alcotest.fail "unexpected transaction commit failure");
        hooks)
      ~update_necessity:(fun context ->
        check_pure_context context;
        record events "update_necessity")
  in
  let rollback =
    Pass.rollback_ops
      ~rollback_staging:(fun context staging ->
        check_rollback_context context;
        check_staging staging;
        record events "rollback_staging";
        S.rollback_transaction state;
        [ "rollback-hook" ])
      ~mark_observers_failed_without_current:(fun context observers ->
        check_rollback_context context;
        record events
          ("mark_observers_failed_without_current:" ^ String.concat ","
             observers))
      ~requeue_pending:(fun context pending ->
        check_rollback_context context;
        record events ("requeue_pending:" ^ String.concat "," pending))
  in
  let timer_refresh =
    Pass.timer_refresh_ops ~clear_active_timer_refresh:(fun context ->
        check_timer_refresh_context context;
        record events "clear_timer_refresh")
  in
  Pass.pass_ops ~errors ~pure ~rollback ~timer_refresh

let test_success_runs_pure_pass_in_order () =
  let events = ref [] in
  let state : test_error stabilization = S.create () in
  let result = Pass.run state capability (ops state events) in
  expect_pure_ok result
    (fun ~hooks ~events:pass_events ~delivering_token:delivering ->
      Alcotest.(check (list string))
        "callback order"
        [
          "advance_generation";
          "begin_staging";
          "drain_pending";
          "release_pending_marks:pending";
          "observer_plan";
          "stage_pending:pending";
          "plan_staged_binds:observer";
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
      ignore (S.finish_delivering state delivering : S.idle token))

let test_graph_error_rolls_back_in_order () =
  let events = ref [] in
  let state : test_error stabilization = S.create () in
  let result =
    Pass.run state capability
      (ops state events ~stage_pending:(fun _ -> raise Graph_failure))
  in
  expect_graph_error result (fun ~hooks -> function
    | `Graph ->
        Alcotest.(check (list string))
          "callback order"
          [
            "advance_generation";
            "begin_staging";
            "drain_pending";
            "release_pending_marks:pending";
            "observer_plan";
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
    | `Reentrant_stabilization ->
        Alcotest.fail "unexpected reentrant error"
    | `Delivery_failed -> Alcotest.fail "unexpected delivery error")

let test_defect_rolls_back_in_order () =
  let events = ref [] in
  let state : test_error stabilization = S.create () in
  let result =
    Pass.run state capability
      (ops state events ~commit_staging:(fun _ -> failwith "boom"))
  in
  expect_defect result (fun ~hooks _ _ ->
      Alcotest.(check (list string))
        "callback order"
        [
          "advance_generation";
          "begin_staging";
          "drain_pending";
          "release_pending_marks:pending";
          "observer_plan";
          "stage_pending:pending";
          "plan_staged_binds:observer";
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
        | S.Pure | S.Committed | S.Delivering -> false))

let test_reentrant_begin_is_graph_error_without_callbacks () =
  let events = ref [] in
  let state : test_error stabilization = S.create () in
  let pure =
    match S.begin_pure state with
    | Ok pure -> pure
    | Error `Reentrant_stabilization -> Alcotest.fail "expected first begin"
  in
  let result = Pass.run state capability (ops state events) in
  expect_graph_error result (fun ~hooks -> function
    | `Reentrant_stabilization ->
        Alcotest.(check (list string)) "no hooks" [] hooks;
        Alcotest.(check (list string)) "no callbacks" [] !events
    | `Graph -> Alcotest.fail "unexpected graph error"
    | `Delivery_failed -> Alcotest.fail "unexpected delivery error");
  S.rollback_transaction state;
  ignore (S.rollback_to_idle state pure : S.idle token)

let expect_idle label state =
  Alcotest.(check bool) (label ^ ": idle") true
    (match S.state state with
    | S.Idle -> true
    | S.Pure | S.Committed | S.Delivering -> false)

let check_failure_slot failure_kind slot =
  let label =
    failure_slot_name slot
    ^
    match failure_kind with
    | Graph_error -> ":graph"
    | Defect -> ":defect"
  in
  let events = ref [] in
  let state : test_error stabilization = S.create () in
  let result =
    Pass.run state capability
      (ops state events ~fail_at:slot ~failure_kind)
  in
  (match failure_kind with
  | Graph_error ->
      expect_graph_error result (fun ~hooks -> function
        | `Graph ->
            Alcotest.(check (list string))
              (label ^ ": hooks") (expected_failure_hooks slot) hooks
        | `Reentrant_stabilization ->
            Alcotest.failf "%s: unexpected reentrant error" label
        | `Delivery_failed ->
            Alcotest.failf "%s: unexpected delivery error" label)
  | Defect ->
      expect_defect result (fun ~hooks exn _ ->
          match exn with
          | Defect_failure ->
              Alcotest.(check (list string))
                (label ^ ": hooks") (expected_failure_hooks slot) hooks
          | _ -> Alcotest.failf "%s: unexpected defect" label));
  Alcotest.(check (list string))
    (label ^ ": events") (expected_failure_events slot) !events;
  expect_idle label state

let test_generated_pure_failure_slots_roll_back () =
  List.iter
    (fun slot ->
      check_failure_slot Graph_error slot;
      check_failure_slot Defect slot)
    failure_slots

let delivery_ops ?(run_events = fun _events -> Eta.Effect.unit) events =
  Pass.delivery_ops
    ~run_pending_cleanup:(fun () ->
      Eta.Effect.sync (fun () -> record events "cleanup"))
    ~run_events:(fun delivery_events ->
      Eta.Effect.sync (fun () ->
          record events ("events:" ^ String.concat "," delivery_events))
      |> Eta.Effect.bind (fun () -> run_events delivery_events))
    ~mark_complete:(fun () ->
      Eta.Effect.sync (fun () -> record events "complete"))
    ~finish:(fun () -> Eta.Effect.sync (fun () -> record events "finish"))

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
          Alcotest.test_case "generated pure failure slots roll back" `Quick
            test_generated_pure_failure_slots_roll_back;
          Alcotest.test_case "delivery success bracketing" `Quick
            test_delivery_success_brackets_cleanup_and_finish;
          Alcotest.test_case "delivery failure bracketing" `Quick
            test_delivery_failure_runs_final_cleanup_and_finish;
        ] );
    ]
