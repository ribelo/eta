open Eta

module Adapter = Eta_signal_timer_adapter
module Timer_policy = Eta_signal_timer_policy

let pp_hidden ppf _ = Format.pp_print_string ppf "<timer-adapter-error>"

let run_ok runtime effect =
  match Eta_eio.Runtime.run runtime effect with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause

let run_error runtime effect =
  match Eta_eio.Runtime.run runtime effect with
  | Exit.Ok _ -> Alcotest.fail "expected Error, got Ok"
  | Exit.Error cause -> cause

let with_runtime f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let runtime =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
      ()
  in
  f runtime

let record events event = events := !events @ [ event ]

let capability = "timer-demand"

let check_cap cap =
  Alcotest.(check string) "capability" capability cap

let adapter_access =
  Adapter.access ~with_access:(fun f ->
      Effect.sync (fun () -> f capability) |> Effect.flatten_result)

let demand_plan ~acquire ~rollback_unclaimed ~run_cancel_hooks
    ~run_start_attempts =
  let claim =
    Adapter.demand_claim_plan
      ~acquire:(fun runtime_contract cap ->
        match acquire runtime_contract cap with
        | Error _ as error -> error
        | Ok (start_attempts, cancel_hooks) ->
            Ok (Adapter.demand_claim ~start_attempts ~cancel_hooks))
      ~rollback_unclaimed
  in
  let effects =
    Adapter.demand_effect_plan ~run_cancel_hooks ~run_start_attempts
  in
  Adapter.demand_plan ~claim ~effects

let loop_plan ~read_next_due ~advance_next_due ~after_update_state
    ~finish_saturated ~construct_update ~after_due_read_before_commit
    ~after_update_constructed_before_run =
  let due =
    Adapter.loop_due_plan ~read_next_due ~advance_next_due
      ~after_due_read_before_commit
  in
  let updates =
    Adapter.loop_update_plan ~after_update_state ~construct_update
      ~after_update_constructed_before_run
  in
  let finish = Adapter.loop_finish_plan ~finish_saturated in
  Adapter.loop_plan ~due ~updates ~finish

let start_plan ~begin_start ~set_next_due ~after_start_update
    ~construct_start_update ~install_cancel ~cleanup_after_exit
    ~cleanup_failed_start =
  let gate = Adapter.start_gate_plan ~begin_start ~set_next_due in
  let update =
    Adapter.start_update_plan ~construct_start_update ~after_start_update
  in
  let daemon =
    Adapter.start_daemon_plan ~install_cancel ~cleanup_after_exit
      ~cleanup_failed_start
  in
  Adapter.start_plan ~gate ~update ~daemon

let check_demand_failed cause =
  match Cause.failures cause with
  | [ `Demand_failed ] -> ()
  | _ ->
      Alcotest.failf "expected Demand_failed, got %a"
        (Cause.pp (fun ppf `Demand_failed ->
             Format.pp_print_string ppf "Demand_failed"))
        cause

let test_cancellable_stop_skips_loop () =
  with_runtime @@ fun runtime ->
  let events = ref [] in
  run_ok runtime
    (Adapter.run_cancellable
       ~install_cancel:(fun ~cancel:_ ->
         Effect.sync (fun () ->
             record events "install_cancel";
             `Stop))
       ~loop:(Effect.sync (fun () -> record events "loop")));
  Alcotest.(check (list string))
    "events" [ "install_cancel" ] !events

let test_refresh_demand_orders_cancel_start_and_rollback () =
  with_runtime @@ fun runtime ->
  let events = ref [] in
  run_ok runtime
    (Adapter.refresh_demand adapter_access
       (demand_plan
          ~acquire:(fun _runtime_contract cap ->
            check_cap cap;
            record events "acquire";
            Ok ([ "start-a"; "start-b" ], [ "cancel-a"; "cancel-b" ]))
          ~rollback_unclaimed:(fun cap attempts ->
            check_cap cap;
            List.iter
              (fun attempt -> record events ("rollback:" ^ attempt))
              attempts;
            Ok [ "rollback-cancel" ])
          ~run_cancel_hooks:(fun hooks ->
            Effect.sync (fun () ->
                List.iter (fun hook -> record events ("cancel:" ^ hook)) hooks))
          ~run_start_attempts:(fun attempts ->
            Effect.sync (fun () ->
                List.iter
                  (fun attempt -> record events ("start:" ^ attempt))
                  attempts))));
  Alcotest.(check (list string))
    "events"
    [
      "acquire";
      "cancel:cancel-a";
      "cancel:cancel-b";
      "start:start-a";
      "start:start-b";
      "rollback:start-a";
      "rollback:start-b";
      "cancel:rollback-cancel";
    ]
    !events

let test_refresh_demand_release_does_not_rerun_cancel_hooks () =
  with_runtime @@ fun runtime ->
  let events = ref [] in
  let cause =
    run_error runtime
      (Adapter.refresh_demand adapter_access
         (demand_plan
            ~acquire:(fun _runtime_contract cap ->
              check_cap cap;
              record events "acquire";
              Ok ([ "start" ], [ "cancel" ]))
            ~rollback_unclaimed:(fun cap attempts ->
              check_cap cap;
              List.iter
                (fun attempt -> record events ("rollback:" ^ attempt))
                attempts;
              Ok [])
            ~run_cancel_hooks:(fun hooks ->
              Effect.sync (fun () ->
                  List.iter
                    (fun hook -> record events ("cancel:" ^ hook))
                    hooks))
            ~run_start_attempts:(fun attempts ->
              Effect.sync (fun () ->
                  List.iter
                    (fun attempt -> record events ("start:" ^ attempt))
                    attempts)
              |> Effect.bind (fun () -> Effect.fail `Demand_failed))))
  in
  check_demand_failed cause;
  Alcotest.(check (list string))
    "events"
    [ "acquire"; "cancel:cancel"; "start:start"; "rollback:start" ]
    !events

let test_refresh_demand_acquire_failure_skips_use_and_release () =
  with_runtime @@ fun runtime ->
  let events = ref [] in
  let cause =
    run_error runtime
      (Adapter.refresh_demand adapter_access
         (demand_plan
            ~acquire:(fun _runtime_contract cap ->
              check_cap cap;
              record events "acquire";
              Error `Demand_failed)
            ~rollback_unclaimed:(fun cap _attempts ->
              check_cap cap;
              record events "rollback";
              Ok [])
            ~run_cancel_hooks:(fun _hooks ->
              Effect.sync (fun () -> record events "cancel"))
            ~run_start_attempts:(fun _attempts ->
              Effect.sync (fun () -> record events "start"))))
  in
  check_demand_failed cause;
  Alcotest.(check (list string)) "events" [ "acquire" ] !events

let test_loop_orders_due_advance_and_update () =
  with_runtime @@ fun runtime ->
  let events = ref [] in
  let updates = ref 0 in
  let plan =
    loop_plan
      ~read_next_due:(fun ~generation ~fallback ->
        Effect.sync (fun () ->
            record events
              ("read:" ^ string_of_int generation ^ ":"
             ^ string_of_int fallback);
            Some fallback))
      ~advance_next_due:(fun ~generation ~expected ~next_due_ms ->
        Effect.sync (fun () ->
            record events
              ("advance:" ^ string_of_int generation ^ ":"
             ^ string_of_int expected ^ ":" ^ string_of_int next_due_ms);
            `Advanced))
      ~after_update_state:(fun ~generation ->
        Effect.sync (fun () ->
            record events ("state:" ^ string_of_int generation);
            if !updates = 0 then `Continue else `Stop))
      ~finish_saturated:(fun ~generation ->
        Effect.sync (fun () ->
            record events ("finish:" ^ string_of_int generation)))
      ~construct_update:(fun ~generation ~missed ->
        record events
          ("construct:" ^ string_of_int generation ^ ":"
         ^ string_of_int missed);
        Effect.sync (fun () ->
            incr updates;
            record events "run"))
      ~after_due_read_before_commit:(fun () ->
        Effect.sync (fun () -> record events "due_hook"))
      ~after_update_constructed_before_run:(fun () ->
        Effect.sync (fun () -> record events "after_construct"))
  in
  run_ok runtime
    (Adapter.run_loop plan ~generation:7 ~interval_ms:10 ~next_due_ms:0
       ~catch_up_policy:Timer_policy.Catch_up_coalesced);
  Alcotest.(check (list string))
    "events"
    [
      "read:7:0";
      "read:7:0";
      "due_hook";
      "advance:7:0:10";
      "state:7";
      "construct:7:1";
      "after_construct";
      "run";
      "state:7";
    ]
    !events

let test_loop_update_rechecks_state_after_construction () =
  with_runtime @@ fun runtime ->
  let events = ref [] in
  let running = ref true in
  let user_calls = ref 0 in
  let plan =
    loop_plan
      ~read_next_due:(fun ~generation:_ ~fallback ->
        Effect.sync (fun () ->
            record events "read";
            Some fallback))
      ~advance_next_due:(fun ~generation:_ ~expected:_ ~next_due_ms:_ ->
        Effect.sync (fun () ->
            record events "advance";
            `Advanced))
      ~after_update_state:(fun ~generation:_ ->
        Effect.sync (fun () ->
            if !running then (
              record events "state:running";
              `Continue)
            else (
              record events "state:stopped";
              `Stop)))
      ~finish_saturated:(fun ~generation:_ ->
        Effect.sync (fun () -> record events "finish"))
      ~construct_update:(fun ~generation:_ ~missed:_ ->
        record events "construct";
        Effect.sync (fun () ->
            record events "run";
            if !running then (
              incr user_calls;
              record events "user")
            else record events "skip"))
      ~after_due_read_before_commit:(fun () ->
        Effect.sync (fun () -> record events "due_hook"))
      ~after_update_constructed_before_run:(fun () ->
        Effect.sync (fun () ->
            running := false;
            record events "after_construct"))
  in
  run_ok runtime
    (Adapter.run_loop plan ~generation:7 ~interval_ms:10 ~next_due_ms:0
       ~catch_up_policy:Timer_policy.Catch_up_coalesced);
  Alcotest.(check int) "user update calls" 0 !user_calls;
  Alcotest.(check (list string))
    "events"
    [
      "read";
      "read";
      "due_hook";
      "advance";
      "state:running";
      "construct";
      "after_construct";
      "run";
      "skip";
      "state:stopped";
    ]
    !events

let test_start_runs_update_before_initial_due () =
  with_runtime @@ fun runtime ->
  let events = ref [] in
  let fail_effect label = Effect.sync (fun () -> Alcotest.fail label) in
  let failing_loop_plan =
    loop_plan
      ~read_next_due:(fun ~generation:_ ~fallback:_ ->
        fail_effect "read_next_due")
      ~advance_next_due:(fun ~generation:_ ~expected:_ ~next_due_ms:_ ->
        fail_effect "advance_next_due")
      ~after_update_state:(fun ~generation:_ ->
        fail_effect "after_update_state")
      ~finish_saturated:(fun ~generation:_ -> fail_effect "finish_saturated")
      ~construct_update:(fun ~generation:_ ~missed:_ ->
        fail_effect "construct_update")
      ~after_due_read_before_commit:(fun () ->
        fail_effect "after_due_read_before_commit")
      ~after_update_constructed_before_run:(fun () ->
        fail_effect "after_update_constructed_before_run")
  in
  let start =
    start_plan
      ~begin_start:(fun ~generation ->
        Effect.sync (fun () ->
            record events ("begin:" ^ string_of_int generation);
            `Continue))
      ~set_next_due:(fun ~generation ~next_due_ms ->
        Effect.sync (fun () ->
            record events
              ("set_due:" ^ string_of_int generation ^ ":"
             ^ string_of_int next_due_ms);
            `Stop))
      ~after_start_update:(fun ~generation ->
        Effect.sync (fun () ->
            record events ("after_update:" ^ string_of_int generation);
            `Continue))
      ~construct_start_update:(fun ~generation ~missed ->
        record events
          ("construct_start:" ^ string_of_int generation ^ ":"
         ^ string_of_int missed);
        Effect.sync (fun () -> record events "run_start"))
      ~install_cancel:(fun ~generation:_ ~cancel:_ ->
        fail_effect "install_cancel")
      ~cleanup_after_exit:(fun ~generation:_ _exit ->
        fail_effect "cleanup_after_exit")
      ~cleanup_failed_start:(fun ~generation _exit ->
        Effect.sync (fun () ->
            record events ("cleanup_failed:" ^ string_of_int generation)))
  in
  run_ok runtime
    (Adapter.start start failing_loop_plan ~generation:3 ~interval_ms:10
       ~update_on_start:true
       ~catch_up_policy:Timer_policy.Catch_up_coalesced);
  Alcotest.(check (list string))
    "events"
    [
      "begin:3";
      "construct_start:3:1";
      "run_start";
      "after_update:3";
      "set_due:3:10";
      "cleanup_failed:3";
    ]
    !events

let () =
  Alcotest.run "eta_signal_timer_adapter"
    [
      ( "timer_adapter",
        [
          Alcotest.test_case "cancellable stop skips loop" `Quick
            test_cancellable_stop_skips_loop;
          Alcotest.test_case "refresh demand plan order" `Quick
            test_refresh_demand_orders_cancel_start_and_rollback;
          Alcotest.test_case "refresh demand release does not rerun cancel hooks"
            `Quick test_refresh_demand_release_does_not_rerun_cancel_hooks;
          Alcotest.test_case "refresh demand acquire failure skips cleanup"
            `Quick test_refresh_demand_acquire_failure_skips_use_and_release;
          Alcotest.test_case "loop plan order" `Quick
            test_loop_orders_due_advance_and_update;
          Alcotest.test_case "loop update rechecks state after construction"
            `Quick test_loop_update_rechecks_state_after_construction;
          Alcotest.test_case "start update before initial due" `Quick
            test_start_runs_update_before_initial_due;
        ] );
    ]
