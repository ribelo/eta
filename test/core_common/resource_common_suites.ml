module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  open Eta

  module E = Effect

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

  let test_resource_manual_refresh () =
    B.with_runtime @@ fun _ctx rt ->
    let source = ref 0 in
    let load = E.named "resource.load" (E.sync (fun () -> !source)) in
    let eff =
      Resource.manual load
      |> E.bind (fun resource ->
             Resource.get resource
             |> E.bind (fun initial ->
                    E.named "source.set" (E.sync (fun () -> source := 1))
                    |> E.bind (fun () -> Resource.refresh resource)
                    |> E.bind (fun () -> Resource.get resource)
                    |> E.map (fun refreshed -> (initial, refreshed))))
    in
    Alcotest.(check (pair int int)) "initial then refreshed" (0, 1)
      (run_ok rt eff)

  let test_resource_failed_refresh_keeps_cached_value () =
    B.with_runtime @@ fun _ctx rt ->
    let source = ref (Ok 0) in
    let load =
      E.named "resource.load" (E.sync (fun () -> !source))
      |> E.bind (function
           | Ok value -> E.pure value
           | Error message -> E.fail (`Refresh_failed message))
    in
    let eff =
      Resource.manual load
      |> E.bind (fun resource ->
             E.named "source.fail"
               (E.sync (fun () -> source := Error "Uh oh!"))
             |> E.bind (fun () -> Resource.refresh resource)
             |> E.bind_error
                  (fun (`Refresh_failed _ : [ `Refresh_failed of string ]) ->
                    E.unit)
             |> E.bind (fun () -> Resource.get resource))
    in
    Alcotest.(check int) "cached value survived failed refresh" 0
      (run_ok rt eff)

  let test_resource_newer_refresh_wins () =
    B.with_test_clock @@ fun ctx _clock rt ->
    let first_started, first_started_resolver = B.create_promise () in
    let second_started, second_started_resolver = B.create_promise () in
    let first_release, first_release_resolver = B.create_promise () in
    let second_release, second_release_resolver = B.create_promise () in
    let calls = ref 0 in
    let load =
      E.named "resource.load"
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
    let resource = run_ok rt (Resource.manual load) in
    let first = B.fork_run ctx rt (Resource.refresh resource) in
    B.await first_started;
    let second = B.fork_run ctx rt (Resource.refresh resource) in
    B.await second_started;
    B.resolve second_release_resolver 2;
    check_exit_ok Alcotest.unit "second refresh" () (B.await second);
    B.resolve first_release_resolver 1;
    check_exit_ok Alcotest.unit "first refresh" () (B.await first);
    Alcotest.(check int) "newer refresh value" 2
      (run_ok rt (Resource.get resource))

  let test_resource_auto_refreshes_on_schedule () =
    B.with_test_clock @@ fun _ctx clock rt ->
    let source = ref 0 in
    let load =
      E.named "resource.auto.load"
        (E.sync (fun () ->
             incr source;
             !source))
    in
    let resource =
      run_ok rt
        (Resource.auto ~load ~schedule:(refresh_schedule 2 (Duration.ms 5)) ())
    in
    Alcotest.(check int) "initial value" 1 (run_ok rt (Resource.get resource));
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    B.yield ();
    Alcotest.(check int) "first refresh" 2
      (run_ok rt (Resource.get resource));
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    B.yield ();
    Alcotest.(check int) "second refresh" 3
      (run_ok rt (Resource.get resource))

  let test_resource_auto_failed_refresh_keeps_cached_value () =
    B.with_test_clock @@ fun _ctx clock rt ->
    let results = ref [ Ok 1; Error "boom"; Ok 2 ] in
    let load =
      E.named "resource.auto.load"
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
    let resource =
      run_ok rt
        (Resource.auto ~load ~schedule:(refresh_schedule 2 (Duration.ms 5))
           ~on_error:(fun err -> errors := err :: !errors) ())
    in
    Alcotest.(check int) "initial value" 1 (run_ok rt (Resource.get resource));
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    B.yield ();
    Alcotest.(check int) "failed refresh keeps old value" 1
      (run_ok rt (Resource.get resource));
    Alcotest.(check (list string)) "observed refresh error" [ "boom" ]
      (List.map (fun (`Refresh_failed message) -> message) (List.rev !errors));
    begin match run_ok rt (Resource.failures resource) with
    | [ Cause.Fail (`Refresh_failed "boom") ] -> ()
    | _ -> Alcotest.fail "expected resource failure sink to record refresh error"
    end;
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    B.yield ();
    Alcotest.(check int) "subsequent refresh updates" 2
      (run_ok rt (Resource.get resource))

  let test_resource_auto_records_loader_defect_and_continues () =
    B.with_test_clock @@ fun _ctx clock rt ->
    let results = ref [ Ok 1; Error (Failure "loader boom"); Ok 2 ] in
    let load =
      E.named "resource.auto.load"
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
    let resource =
      run_ok rt
        (Resource.auto ~load ~schedule:(refresh_schedule 2 (Duration.ms 5)) ())
    in
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    B.yield ();
    Alcotest.(check int) "loader defect keeps old value" 1
      (run_ok rt (Resource.get resource));
    begin match run_ok rt (Resource.failures resource) with
    | [ Cause.Die die ] ->
        Alcotest.(check string) "loader defect" "Failure(\"loader boom\")"
          (Printexc.to_string die.exn)
    | _ -> Alcotest.fail "expected loader defect to be recorded"
    end;
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    B.yield ();
    Alcotest.(check int) "refresh loop continued" 2
      (run_ok rt (Resource.get resource))

  let test_resource_auto_records_on_error_defect_and_continues () =
    B.with_test_clock @@ fun _ctx clock rt ->
    let results = ref [ Ok 1; Error "boom"; Ok 2 ] in
    let load =
      E.named "resource.auto.load"
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
    let resource =
      run_ok rt
        (Resource.auto ~load ~schedule:(refresh_schedule 2 (Duration.ms 5))
           ~on_error:(fun (`Refresh_failed _) -> failwith "observer boom") ())
    in
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    B.yield ();
    begin match run_ok rt (Resource.failures resource) with
    | [ Cause.Fail (`Refresh_failed "boom"); Cause.Die die ] ->
        Alcotest.(check string) "on_error defect" "Failure(\"observer boom\")"
          (Printexc.to_string die.exn)
    | _ -> Alcotest.fail "expected typed failure and on_error defect"
    end;
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    B.yield ();
    Alcotest.(check int) "refresh loop continued" 2
      (run_ok rt (Resource.get resource))

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
      ( "Resource",
        [
          Alcotest.test_case "manual refresh" `Quick
            test_resource_manual_refresh;
          Alcotest.test_case "failed refresh keeps cached value" `Quick
            test_resource_failed_refresh_keeps_cached_value;
          Alcotest.test_case "newer refresh wins" `Quick
            test_resource_newer_refresh_wins;
          Alcotest.test_case "auto refreshes on schedule" `Quick
            test_resource_auto_refreshes_on_schedule;
          Alcotest.test_case "auto failed refresh keeps cached value" `Quick
            test_resource_auto_failed_refresh_keeps_cached_value;
          Alcotest.test_case "auto records loader defect and continues" `Quick
            test_resource_auto_records_loader_defect_and_continues;
          Alcotest.test_case "auto records on_error defect and continues" `Quick
            test_resource_auto_records_on_error_defect_and_continues;
        ] );
    ]
end
