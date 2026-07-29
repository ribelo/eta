module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  open Eta

  module E = Effect
  module Refreshable = Eta_cache.Refreshable

  let pp_hidden ppf _ = Format.pp_print_string ppf "<resource>"

  let run_ok rt eff =
    match B.run rt eff with
    | Exit.Ok value -> value
    | Exit.Error cause ->
        Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause

  let check_exit_ok testable label expected = function
    | Exit.Ok actual -> Alcotest.check testable label expected actual
    | Exit.Error cause ->
        Alcotest.failf "%s: expected Ok, got %a" label
          (Cause.pp pp_hidden) cause

  let wait_until ?(attempts = 200) pred =
    let rec loop n =
      if pred () then ()
      else if n = 0 then Alcotest.fail "condition did not become true"
      else (
        B.yield ();
        loop (n - 1))
    in
    loop attempts

  let wait_for_sleepers clock expected =
    wait_until (fun () -> B.sleeper_count clock >= expected)

  let refresh_schedule count delay =
    Schedule.both (Schedule.recurs count) (Schedule.spaced delay)

  let test_clock_sleep_without_wall_time () =
    B.with_test_clock @@ fun ctx clock rt ->
    let promise =
      B.fork_run ctx rt
        (E.pure "elapsed" |> E.delay (Duration.hours 10))
    in
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.hours 11);
    check_exit_ok Alcotest.string "elapsed" "elapsed" (B.await promise)

  let test_clock_sleep_delays_until_adjusted () =
    B.with_test_clock @@ fun ctx clock rt ->
    let promise =
      B.fork_run ctx rt
        (E.pure "elapsed" |> E.delay (Duration.hours 10))
    in
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.hours 9);
    B.yield ();
    Alcotest.(check bool) "not elapsed after 9h" false
      (B.is_resolved promise);
    B.adjust_clock clock (Duration.hours 1);
    check_exit_ok Alcotest.string "elapsed" "elapsed" (B.await promise)

  let test_clock_sleep_handles_multiple_sleeps () =
    B.with_test_clock @@ fun ctx clock rt ->
    let append message acc = acc ^ message in
    let slow =
      E.pure (append "World!")
      |> E.delay (Duration.hours 3)
    in
    let fast =
      E.pure (append "Hello, ")
      |> E.delay (Duration.hours 1)
    in
    let promise = B.fork_run ctx rt (E.race [ slow; fast ]) in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.hours 1);
    let f =
      match B.await promise with
      | Exit.Ok f -> f
      | Exit.Error cause ->
          Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause
    in
    Alcotest.(check string) "first sleeper wins" "Hello, " (f "")

  let test_clock_set_time_wakes_due_sleepers () =
    B.with_test_clock @@ fun ctx clock rt ->
    let promise =
      B.fork_run ctx rt
        (E.pure "elapsed" |> E.delay (Duration.hours 10))
    in
    wait_for_sleepers clock 1;
    B.set_clock clock (Duration.to_ms (Duration.hours 11));
    check_exit_ok Alcotest.string "elapsed after set_time" "elapsed"
      (B.await promise)

  let test_scope_finalizers_run_lifo_sequentially () =
    B.with_test_clock @@ fun ctx clock rt ->
    let released = ref [] in
    let resource name =
      E.acquire_release ~acquire:E.unit ~release:(fun () ->
          E.named ("release." ^ name)
            (E.sync (fun () -> released := name :: !released))
          |> E.delay (Duration.seconds 1))
    in
    let promise =
      B.fork_run ctx rt
        (E.with_scope (E.concat [ resource "a"; resource "b"; resource "c" ]))
    in
    B.yield ();
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.seconds 1);
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.seconds 1);
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.seconds 1);
    check_exit_ok Alcotest.unit "scope done" () (B.await promise);
    Alcotest.(check (list string))
      "lifo release order" [ "c"; "b"; "a" ] (List.rev !released)

  let rec wait_effect predicate =
    E.sync predicate
    |> E.bind (function
         | true -> E.unit
         | false -> E.yield |> E.bind (fun () -> wait_effect predicate))

  let with_running_auto ?on_refresh_error ctx rt ~load ~schedule use =
    let ready, ready_resolver = B.create_promise () in
    let stop, stop_resolver = B.create_promise () in
    let body refreshable =
      E.sync (fun () -> B.resolve ready_resolver refreshable)
      |> E.bind (fun () -> B.await_effect stop)
    in
    let program =
      match on_refresh_error with
      | None -> Refreshable.with_auto ~load ~schedule body
      | Some on_refresh_error ->
          Refreshable.with_auto_on_refresh_error ~on_refresh_error ~load
            ~schedule body
    in
    let running =
      B.fork_run ctx rt program
    in
    let refreshable = B.await ready in
    Fun.protect
      ~finally:(fun () ->
        B.resolve stop_resolver ();
        check_exit_ok Alcotest.unit "with_auto body" () (B.await running))
      (fun () -> use refreshable)

  let test_refreshable_manual_refresh () =
    B.with_runtime @@ fun _ctx rt ->
    let source = ref 0 in
    let load = E.named "refreshable.load" (E.sync (fun () -> !source)) in
    let eff =
      Refreshable.manual load
      |> E.bind (fun refreshable ->
             Refreshable.get refreshable
             |> E.bind (fun initial ->
                    E.named "source.set" (E.sync (fun () -> source := 1))
                    |> E.bind (fun () -> Refreshable.refresh refreshable)
                    |> E.bind (fun () -> Refreshable.get refreshable)
                    |> E.map (fun refreshed -> (initial, refreshed))))
    in
    Alcotest.(check (pair int int)) "initial then refreshed" (0, 1)
      (run_ok rt eff)

  let test_refreshable_manual_seed_failure_returns_no_handle () =
    B.with_runtime @@ fun _ctx rt ->
    match B.run rt (Refreshable.manual (E.fail `Seed_failed)) with
    | Exit.Error (Cause.Fail `Seed_failed) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected seed failure, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "manual seed failure returned a handle"

  let test_refreshable_manual_failures_start_empty () =
    B.with_runtime @@ fun _ctx rt ->
    let failures =
      Refreshable.manual (E.pure 1)
      |> E.bind (fun refreshable -> Refreshable.failures refreshable)
      |> run_ok rt
    in
    Alcotest.(check int) "no automatic failures" 0 (List.length failures)

  let test_refreshable_failed_refresh_keeps_cached_value () =
    B.with_runtime @@ fun _ctx rt ->
    let source = ref (Ok 0) in
    let load =
      E.named "refreshable.load" (E.sync (fun () -> !source))
      |> E.bind (function
           | Ok value -> E.pure value
           | Error message -> E.fail (`Refresh_failed message))
    in
    let eff =
      Refreshable.manual load
      |> E.bind (fun refreshable ->
             E.named "source.fail"
               (E.sync (fun () -> source := Error "Uh oh!"))
             |> E.bind (fun () -> Refreshable.refresh refreshable)
             |> E.bind_error
                  (fun (`Refresh_failed _ : [ `Refresh_failed of string ]) ->
                    E.unit)
             |> E.bind (fun () -> Refreshable.get refreshable))
    in
    Alcotest.(check int) "cached value survived failed refresh" 0
      (run_ok rt eff)

  let test_refreshable_newer_refresh_wins () =
    B.with_test_clock @@ fun ctx _clock rt ->
    let first_started, first_started_resolver = B.create_promise () in
    let second_started, second_started_resolver = B.create_promise () in
    let first_release, first_release_resolver = B.create_promise () in
    let second_release, second_release_resolver = B.create_promise () in
    let calls = ref 0 in
    let load =
      E.named "refreshable.load"
        (E.sync (fun () ->
             incr calls;
             !calls)
        |> E.bind (function
             | 1 -> E.pure 0
             | 2 ->
                 E.sync (fun () -> B.resolve first_started_resolver ())
                 |> E.bind (fun () -> B.await_effect first_release)
             | 3 ->
                 E.sync (fun () -> B.resolve second_started_resolver ())
                 |> E.bind (fun () -> B.await_effect second_release)
             | n ->
                 E.sync (fun () -> Alcotest.failf "unexpected load call %d" n)))
    in
    let refreshable = run_ok rt (Refreshable.manual load) in
    let first = B.fork_run ctx rt (Refreshable.refresh refreshable) in
    B.await first_started;
    Alcotest.(check int) "stale value while refresh runs" 0
      (run_ok rt (Refreshable.get refreshable));
    let second = B.fork_run ctx rt (Refreshable.refresh refreshable) in
    B.await second_started;
    B.resolve second_release_resolver 2;
    check_exit_ok Alcotest.unit "second refresh" () (B.await second);
    B.resolve first_release_resolver 1;
    check_exit_ok Alcotest.unit "first refresh" () (B.await first);
    Alcotest.(check int) "newer refresh value" 2
      (run_ok rt (Refreshable.get refreshable))

  let test_refreshable_with_auto_refreshes_on_schedule () =
    B.with_test_clock @@ fun ctx clock rt ->
    let source = ref 0 in
    let load =
      E.named "refreshable.with_auto.load"
        (E.sync (fun () ->
             incr source;
             !source))
    in
    with_running_auto ctx rt ~load
      ~schedule:(refresh_schedule 2 (Duration.ms 5))
    @@ fun refreshable ->
    Alcotest.(check int) "initial value" 1
      (run_ok rt (Refreshable.get refreshable));
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    wait_for_sleepers clock 1;
    Alcotest.(check int) "first refresh" 2
      (run_ok rt (Refreshable.get refreshable));
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    wait_until (fun () -> run_ok rt (Refreshable.get refreshable) = 3);
    Alcotest.(check int) "second refresh" 3
      (run_ok rt (Refreshable.get refreshable))

  let test_refreshable_with_auto_callback_forms_erase_optionals () =
    B.with_runtime @@ fun _ctx rt ->
    let load : (int, [ `Refresh_failed ]) E.t = E.pure 7 in
    let schedule = Schedule.recurs 0 in
    let via_let_at =
      let open Syntax in
      let@ refreshable = Refreshable.with_auto ~load ~schedule in
      Refreshable.get refreshable
    in
    let direct =
      Refreshable.with_auto ~load ~schedule (fun refreshable ->
          Refreshable.get refreshable)
    in
    let alerted_via_let_at =
      let open Syntax in
      let@ refreshable =
        Refreshable.with_auto_on_refresh_error
          ~on_refresh_error:(fun `Refresh_failed -> ()) ~load ~schedule
      in
      Refreshable.get refreshable
    in
    let alerted_direct =
      Refreshable.with_auto_on_refresh_error
        ~on_refresh_error:(fun `Refresh_failed -> ()) ~load ~schedule
        (fun refreshable -> Refreshable.get refreshable)
    in
    Alcotest.(check (list int)) "both let@ and direct forms" [ 7; 7; 7; 7 ]
      (run_ok rt (E.all [ via_let_at; direct; alerted_via_let_at; alerted_direct ]))

  let test_refreshable_with_auto_uses_scoped_or_runtime_random () =
    let schedule =
      Schedule.both (Schedule.recurs 2)
        (Schedule.spaced (Duration.ms 100)
        |> Schedule.jittered ~min:0.5 ~max:1.5)
    in
    let expected seed =
      let rec collect driver delays =
        match Schedule.step ~now_ms:0 ~input:() driver with
        | Schedule.Done _, _ -> List.rev delays
        | Schedule.Continue metadata, driver' ->
            collect driver' (Duration.to_ms metadata.delay :: delays)
      in
      collect
        (Schedule.start ~random:(Capabilities.random_of_seed seed) schedule)
        []
    in
    let run ~runtime_seed ?override_seed () =
      B.with_seeded_logged_test_clock ~seed:runtime_seed
      @@ fun ctx clock rt sleeps ->
      let calls = ref 0 in
      let load = E.sync (fun () -> incr calls; !calls) in
      let program =
        Refreshable.with_auto ~load ~schedule (fun _refreshable ->
            wait_effect (fun () -> !calls = 3))
      in
      let program =
        match override_seed with
        | None -> program
        | Some seed ->
            E.with_random (Capabilities.random_of_seed seed) program
      in
      let running = B.fork_run ctx rt program in
      wait_until (fun () -> List.length !sleeps = 1);
      B.adjust_clock clock (List.hd !sleeps);
      wait_until (fun () -> List.length !sleeps = 2);
      B.adjust_clock clock (List.hd !sleeps);
      check_exit_ok Alcotest.unit "jittered with_auto" () (B.await running);
      List.rev_map Duration.to_ms !sleeps
    in
    let scoped_expected = expected 1234 in
    let runtime_expected = expected 5678 in
    Alcotest.(check bool) "seeds discriminate" true
      (scoped_expected <> runtime_expected);
    Alcotest.(check (list int)) "scoped random first run" scoped_expected
      (run ~runtime_seed:17 ~override_seed:1234 ());
    Alcotest.(check (list int)) "scoped random replay" scoped_expected
      (run ~runtime_seed:23 ~override_seed:1234 ());
    Alcotest.(check (list int)) "runtime default" runtime_expected
      (run ~runtime_seed:5678 ())

  let test_refreshable_with_auto_failed_refresh_keeps_cached_value () =
    B.with_test_clock @@ fun ctx clock rt ->
    let results = ref [ Ok 1; Error "boom"; Ok 2 ] in
    let load =
      E.named "refreshable.with_auto.load"
        (E.sync (fun () ->
             match !results with
             | [] -> Ok 999
             | result :: rest ->
                 results := rest;
                 result))
      |> E.bind (function
           | Ok value -> E.pure value
           | Error message -> E.fail (`Refresh_failed message))
    in
    let errors = ref [] in
    with_running_auto ctx rt ~load
      ~schedule:(refresh_schedule 2 (Duration.ms 5))
      ~on_refresh_error:(fun err -> errors := err :: !errors)
    @@ fun refreshable ->
    Alcotest.(check int) "initial value" 1
      (run_ok rt (Refreshable.get refreshable));
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    wait_for_sleepers clock 1;
    Alcotest.(check int) "failed refresh keeps old value" 1
      (run_ok rt (Refreshable.get refreshable));
    Alcotest.(check (list string)) "observed refresh error" [ "boom" ]
      (List.map (fun (`Refresh_failed message) -> message) (List.rev !errors));
    begin match run_ok rt (Refreshable.failures refreshable) with
    | [ Cause.Fail (`Refresh_failed "boom") ] -> ()
    | _ -> Alcotest.fail "expected refreshable failure sink to record refresh error"
    end;
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    wait_until (fun () -> run_ok rt (Refreshable.get refreshable) = 2);
    Alcotest.(check int) "subsequent refresh updates" 2
      (run_ok rt (Refreshable.get refreshable))

  let test_refreshable_with_auto_records_loader_defect_and_continues () =
    B.with_test_clock @@ fun ctx clock rt ->
    let results = ref [ Ok 1; Error (Failure "loader boom"); Ok 2 ] in
    let callback_calls = ref 0 in
    let load =
      E.named "refreshable.with_auto.load"
        (E.sync (fun () ->
             match !results with
             | [] -> 999
             | Ok value :: rest ->
                 results := rest;
                 value
             | Error exn :: rest ->
                 results := rest;
                 raise exn))
    in
    with_running_auto ctx rt ~load
      ~schedule:(refresh_schedule 2 (Duration.ms 5))
      ~on_refresh_error:(fun _ -> incr callback_calls)
    @@ fun refreshable ->
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    wait_for_sleepers clock 1;
    Alcotest.(check int) "loader defect keeps old value" 1
      (run_ok rt (Refreshable.get refreshable));
    begin match run_ok rt (Refreshable.failures refreshable) with
    | [ Cause.Die die ] ->
        Alcotest.(check string) "loader defect" "Failure(\"loader boom\")"
          (Printexc.to_string die.exn)
    | _ -> Alcotest.fail "expected loader defect to be recorded"
    end;
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    wait_until (fun () -> run_ok rt (Refreshable.get refreshable) = 2);
    Alcotest.(check int) "refresh loop continued" 2
      (run_ok rt (Refreshable.get refreshable));
    Alcotest.(check int) "loader defect not sent to typed callback" 0
      !callback_calls

  let test_refreshable_with_auto_records_on_refresh_error_defect_and_continues () =
    B.with_test_clock @@ fun ctx clock rt ->
    let results = ref [ Ok 1; Error "boom"; Ok 2 ] in
    let load =
      E.named "refreshable.with_auto.load"
        (E.sync (fun () ->
             match !results with
             | [] -> Ok 999
             | result :: rest ->
                 results := rest;
                 result))
      |> E.bind (function
           | Ok value -> E.pure value
           | Error message -> E.fail (`Refresh_failed message))
    in
    with_running_auto ctx rt ~load
      ~schedule:(refresh_schedule 2 (Duration.ms 5))
      ~on_refresh_error:(fun (`Refresh_failed _) -> failwith "observer boom")
    @@ fun refreshable ->
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    wait_for_sleepers clock 1;
    begin match run_ok rt (Refreshable.failures refreshable) with
    | [ Cause.Fail (`Refresh_failed "boom"); Cause.Die die ] ->
        Alcotest.(check string) "on_refresh_error defect"
          "Failure(\"observer boom\")"
          (Printexc.to_string die.exn)
    | _ -> Alcotest.fail "expected typed failure and on_refresh_error defect"
    end;
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    wait_until (fun () -> run_ok rt (Refreshable.get refreshable) = 2);
    Alcotest.(check int) "refresh loop continued" 2
      (run_ok rt (Refreshable.get refreshable))

  let blocked_refresh_load started started_resolver finalized calls =
    E.sync (fun () ->
        incr calls;
        !calls)
    |> E.bind (function
         | 1 -> E.pure 1
         | _ ->
             E.sync (fun () -> B.resolve started_resolver ())
             |> E.bind (fun () ->
                    E.finally
                      (E.sync (fun () -> finalized := true))
                      E.never))

  let assert_blocked_refresh_stopped finalized calls =
    Alcotest.(check bool) "in-flight refresh finalized" true !finalized;
    Alcotest.(check int) "seed plus one refresh" 2 !calls;
    B.yield ();
    Alcotest.(check int) "refresh loop stayed stopped" 2 !calls

  let test_refreshable_with_auto_stops_loop_on_body_success () =
    B.with_runtime @@ fun _ctx rt ->
    let started, started_resolver = B.create_promise () in
    let finalized = ref false in
    let calls = ref 0 in
    let load = blocked_refresh_load started started_resolver finalized calls in
    let program =
      Refreshable.with_auto ~load ~schedule:(Schedule.recurs 1)
        (fun _refreshable -> B.await_effect started)
    in
    check_exit_ok Alcotest.unit "body success" () (B.run rt program);
    assert_blocked_refresh_stopped finalized calls

  let test_refreshable_with_auto_stops_loop_on_body_typed_failure () =
    B.with_runtime @@ fun _ctx rt ->
    let started, started_resolver = B.create_promise () in
    let finalized = ref false in
    let calls = ref 0 in
    let callback_calls = ref 0 in
    let load = blocked_refresh_load started started_resolver finalized calls in
    let program =
      Refreshable.with_auto_on_refresh_error
        ~on_refresh_error:(fun _ -> incr callback_calls) ~load
        ~schedule:(Schedule.recurs 1)
        (fun _refreshable ->
          B.await_effect started |> E.bind (fun () -> E.fail `Body_failed))
    in
    begin match B.run rt program with
    | Exit.Error (Cause.Fail `Body_failed) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected body failure, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected body failure"
    end;
    assert_blocked_refresh_stopped finalized calls;
    Alcotest.(check int) "body typed failure not observed as refresh" 0
      !callback_calls

  let test_refreshable_with_auto_stops_loop_on_body_defect () =
    B.with_runtime @@ fun _ctx rt ->
    let started, started_resolver = B.create_promise () in
    let finalized = ref false in
    let calls = ref 0 in
    let callback_calls = ref 0 in
    let defect = Failure "body boom" in
    let load = blocked_refresh_load started started_resolver finalized calls in
    let program =
      Refreshable.with_auto_on_refresh_error
        ~on_refresh_error:(fun _ -> incr callback_calls) ~load
        ~schedule:(Schedule.recurs 1)
        (fun _refreshable ->
          B.await_effect started
          |> E.bind (fun () -> E.sync (fun () -> raise defect)))
    in
    begin match B.run rt program with
    | Exit.Error (Cause.Die die) when die.exn == defect -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected body defect, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected body defect"
    end;
    assert_blocked_refresh_stopped finalized calls;
    Alcotest.(check int) "body defect not observed as refresh" 0 !callback_calls

  let test_refreshable_with_auto_stops_loop_on_body_cancellation () =
    B.with_runtime @@ fun ctx rt ->
    let started, started_resolver = B.create_promise () in
    let finalized = ref false in
    let calls = ref 0 in
    let load = blocked_refresh_load started started_resolver finalized calls in
    let running =
      B.fork_run_cancelable ctx rt
        (Refreshable.with_auto ~load ~schedule:(Schedule.recurs 1)
           (fun _refreshable ->
             B.await_effect started |> E.bind (fun () -> E.never)))
    in
    B.await started;
    B.cancel_fiber running;
    begin match B.await_cancelable running with
    | `Cancelled -> ()
    | `Returned (Exit.Error cause) when Cause.is_interrupt_only cause -> ()
    | `Returned (Exit.Error cause) ->
        Alcotest.failf "expected body interruption, got %a"
          (Cause.pp pp_hidden) cause
    | `Returned (Exit.Ok _) ->
        Alcotest.fail "cancelled with_auto body returned successfully"
    end;
    assert_blocked_refresh_stopped finalized calls

  let test_refreshable_with_auto_cancels_and_finalizes_in_flight_refresh () =
    B.with_runtime @@ fun ctx rt ->
    let refresh_started, refresh_started_resolver = B.create_promise () in
    let cleanup_started, cleanup_started_resolver = B.create_promise () in
    let cleanup_release, cleanup_release_resolver = B.create_promise () in
    let calls = ref 0 in
    let load =
      E.sync (fun () ->
          incr calls;
          !calls)
      |> E.bind (function
           | 1 -> E.pure 1
           | _ ->
               E.sync (fun () -> B.resolve refresh_started_resolver ())
               |> E.bind (fun () ->
                      E.finally
                        (E.sync (fun () -> B.resolve cleanup_started_resolver ())
                        |> E.bind (fun () -> B.await_effect cleanup_release))
                        E.never))
    in
    let running =
      B.fork_run ctx rt
        (Refreshable.with_auto ~load ~schedule:(Schedule.recurs 1)
           (fun _refreshable -> B.await_effect refresh_started))
    in
    B.await cleanup_started;
    Alcotest.(check bool) "scope waits for refresh finalizer" false
      (B.is_resolved running);
    B.resolve cleanup_release_resolver ();
    check_exit_ok Alcotest.unit "scope exits after finalizer" () (B.await running)

  let test_refreshable_with_auto_seed_failure_skips_body () =
    B.with_runtime @@ fun _ctx rt ->
    let body_ran = ref false in
    let callback_calls = ref 0 in
    let program =
      Refreshable.with_auto_on_refresh_error
        ~on_refresh_error:(fun `Seed_failed -> incr callback_calls)
        ~load:(E.fail `Seed_failed)
        ~schedule:(Schedule.recurs 1)
        (fun _refreshable -> E.sync (fun () -> body_ran := true))
    in
    begin match B.run rt program with
    | Exit.Error (Cause.Fail `Seed_failed) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected seed failure, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "seed failure unexpectedly succeeded"
    end;
    Alcotest.(check bool) "body did not run" false !body_ran;
    Alcotest.(check int) "seed failure not observed as refresh" 0 !callback_calls

  let test_refreshable_with_auto_schedule_exhaustion_keeps_handle_usable () =
    B.with_runtime @@ fun _ctx rt ->
    let calls = ref 0 in
    let load = E.sync (fun () -> incr calls; !calls) in
    let program =
      Refreshable.with_auto ~load ~schedule:(Schedule.recurs 1)
        (fun refreshable ->
          wait_effect (fun () -> !calls = 2)
          |> E.bind (fun () -> E.yield)
          |> E.bind (fun () -> Refreshable.get refreshable)
          |> E.map (fun value -> (value, !calls)))
    in
    let value, calls = run_ok rt program in
    Alcotest.(check int) "last refreshed value" 2 value;
    Alcotest.(check int) "seed plus exact scheduled refreshes" 2 calls

  let test_refreshable_failures_preserve_fail_die_observation_order () =
    B.with_runtime @@ fun _ctx rt ->
    let calls = ref 0 in
    let load =
      E.sync (fun () ->
          incr calls;
          !calls)
      |> E.bind (function
           | 1 -> E.pure 1
           | 2 -> E.fail `First_refresh_failed
           | 3 -> E.sync (fun () -> raise (Failure "second refresh died"))
           | _ -> E.pure 4)
    in
    let rec await_failures refreshable =
      Refreshable.failures refreshable
      |> E.bind (fun failures ->
             if List.length failures = 2 then E.pure failures
             else E.yield |> E.bind (fun () -> await_failures refreshable))
    in
    let rec await_value refreshable =
      Refreshable.get refreshable
      |> E.bind (fun value ->
             if value = 4 then E.pure value
             else E.yield |> E.bind (fun () -> await_value refreshable))
    in
    let program =
      Refreshable.with_auto ~load ~schedule:(Schedule.recurs 3)
        (fun refreshable ->
          await_failures refreshable
          |> E.bind (fun failures ->
                 await_value refreshable
                 |> E.map (fun value -> (failures, value))))
    in
    let failures, value = run_ok rt program in
    Alcotest.(check int) "later successful refresh published" 4 value;
    begin match failures with
    | [ Cause.Fail `First_refresh_failed; Cause.Die die ] ->
        Alcotest.(check string) "defect order" "Failure(\"second refresh died\")"
          (Printexc.to_string die.exn)
    | _ -> Alcotest.fail "expected Fail then Die in observation order"
    end

  let tests =
    [
      ( "Clock",
        [
          Alcotest.test_case "sleep without wall time" `Quick
            test_clock_sleep_without_wall_time;
          Alcotest.test_case "sleep delays until adjusted" `Quick
            test_clock_sleep_delays_until_adjusted;
          Alcotest.test_case "multiple sleeps" `Quick
            test_clock_sleep_handles_multiple_sleeps;
          Alcotest.test_case "set_time wakes due sleepers" `Quick
            test_clock_set_time_wakes_due_sleepers;
        ] );
      ( "Scope",
        [
          Alcotest.test_case "finalizers run lifo sequentially" `Quick
            test_scope_finalizers_run_lifo_sequentially;
        ] );
      ( "Refreshable",
        [
          Alcotest.test_case "manual refresh" `Quick
            test_refreshable_manual_refresh;
          Alcotest.test_case "manual seed failure returns no handle" `Quick
            test_refreshable_manual_seed_failure_returns_no_handle;
          Alcotest.test_case "manual failures start empty" `Quick
            test_refreshable_manual_failures_start_empty;
          Alcotest.test_case "failed refresh keeps cached value" `Quick
            test_refreshable_failed_refresh_keeps_cached_value;
          Alcotest.test_case "newer refresh wins" `Quick
            test_refreshable_newer_refresh_wins;
          Alcotest.test_case "with_auto refreshes on schedule" `Quick
            test_refreshable_with_auto_refreshes_on_schedule;
          Alcotest.test_case "with_auto callback forms erase optionals" `Quick
            test_refreshable_with_auto_callback_forms_erase_optionals;
          Alcotest.test_case "with_auto uses scoped or runtime random" `Quick
            test_refreshable_with_auto_uses_scoped_or_runtime_random;
          Alcotest.test_case "with_auto failed refresh keeps cached value" `Quick
            test_refreshable_with_auto_failed_refresh_keeps_cached_value;
          Alcotest.test_case "with_auto records loader defect and continues" `Quick
            test_refreshable_with_auto_records_loader_defect_and_continues;
          Alcotest.test_case
            "with_auto_on_refresh_error records callback defect and continues"
            `Quick
            test_refreshable_with_auto_records_on_refresh_error_defect_and_continues;
          Alcotest.test_case "with_auto stops loop on body success" `Quick
            test_refreshable_with_auto_stops_loop_on_body_success;
          Alcotest.test_case "with_auto stops loop on body typed failure" `Quick
            test_refreshable_with_auto_stops_loop_on_body_typed_failure;
          Alcotest.test_case "with_auto stops loop on body defect" `Quick
            test_refreshable_with_auto_stops_loop_on_body_defect;
          Alcotest.test_case "with_auto stops loop on body cancellation" `Quick
            test_refreshable_with_auto_stops_loop_on_body_cancellation;
          Alcotest.test_case "with_auto cancels and finalizes in-flight refresh"
            `Quick test_refreshable_with_auto_cancels_and_finalizes_in_flight_refresh;
          Alcotest.test_case "with_auto seed failure skips body" `Quick
            test_refreshable_with_auto_seed_failure_skips_body;
          Alcotest.test_case "with_auto schedule exhaustion keeps handle usable"
            `Quick test_refreshable_with_auto_schedule_exhaustion_keeps_handle_usable;
          Alcotest.test_case "failures preserve Fail Die observation order" `Quick
            test_refreshable_failures_preserve_fail_die_observation_order;
        ] );
    ]
end
