open Eta
open Eta_test
open Test_eta_support

let test_clock_sleep_without_wall_time () =
  with_test_clock @@ fun sw clock rt ->
  let promise =
    fork_run sw rt
      (Effect.pure "elapsed" |> Effect.delay (Duration.hours 10))
  in
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.hours 11);
  check_exit_ok Alcotest.string "elapsed" "elapsed"
    (Eio.Promise.await promise)

let test_clock_sleep_delays_until_adjusted () =
  with_test_clock @@ fun sw clock rt ->
  let promise =
    fork_run sw rt
      (Effect.pure "elapsed" |> Effect.delay (Duration.hours 10))
  in
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.hours 9);
  yield ();
  Alcotest.(check bool) "not elapsed after 9h" false
    (Eio.Promise.is_resolved promise);
  Test_clock.adjust clock (Duration.hours 1);
  check_exit_ok Alcotest.string "elapsed" "elapsed"
    (Eio.Promise.await promise)

let test_clock_sleep_handles_multiple_sleeps () =
  with_test_clock @@ fun sw clock rt ->
  let append message acc = acc ^ message in
  let slow =
    Effect.pure (append "World!")
    |> Effect.delay (Duration.hours 3)
  in
  let fast =
    Effect.pure (append "Hello, ")
    |> Effect.delay (Duration.hours 1)
  in
  let promise = fork_run sw rt (Effect.race [ slow; fast ]) in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.hours 1);
  let f =
    match Eio.Promise.await promise with
    | Exit.Ok f -> f
    | Exit.Error _ -> Alcotest.fail "expected Ok"
  in
  Alcotest.(check string) "first sleeper wins" "Hello, " (f "")

let test_clock_set_time_wakes_due_sleepers () =
  with_test_clock @@ fun sw clock rt ->
  let promise =
    fork_run sw rt
      (Effect.pure "elapsed" |> Effect.delay (Duration.hours 10))
  in
  wait_for_sleepers clock 1;
  Test_clock.set_time clock (Duration.to_ms (Duration.hours 11));
  check_exit_ok Alcotest.string "elapsed after set_time" "elapsed"
    (Eio.Promise.await promise)

let test_scope_finalizers_run_lifo_sequentially () =
  with_test_clock @@ fun sw clock rt ->
  let released = ref [] in
  let resource name =
    Effect.acquire_release ~acquire:Effect.unit ~release:(fun () ->
        Effect.named ("release." ^ name)
          (Effect.sync (fun () -> released := name :: !released))
        |> Effect.delay (Duration.seconds 1))
  in
  let promise =
    fork_run sw rt
      (Effect.scoped
         (Effect.concat [ resource "a"; resource "b"; resource "c" ]))
  in
  yield ();
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.seconds 1);
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.seconds 1);
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.seconds 1);
  check_exit_ok Alcotest.unit "scope done" () (Eio.Promise.await promise);
  Alcotest.(check (list string))
    "lifo release order" [ "c"; "b"; "a" ] (List.rev !released)

let test_resource_manual_refresh () =
  with_runtime @@ fun rt ->
  let source = ref 0 in
  let load = Effect.named "resource.load" (Effect.sync (fun () -> !source)) in
  let eff =
    Resource.manual load
    |> Effect.bind (fun resource ->
           Resource.get resource
           |> Effect.bind (fun initial ->
                  Effect.named "source.set" (Effect.sync (fun () -> source := 1))
                  |> Effect.bind (fun () -> Resource.refresh resource)
                  |> Effect.bind (fun () -> Resource.get resource)
                  |> Effect.map (fun refreshed -> (initial, refreshed))))
  in
  Alcotest.(check (pair int int)) "initial then refreshed" (0, 1)
    (run_ok rt eff)

let test_resource_failed_refresh_keeps_cached_value () =
  with_runtime @@ fun rt ->
  let source = ref (Ok 0) in
  let load =
    Effect.named "resource.load" (Effect.sync (fun () -> !source))
    |> Effect.bind (function
         | Ok value -> Effect.pure value
         | Error message -> Effect.fail (`Refresh_failed message))
  in
  let eff =
    Resource.manual load
    |> Effect.bind (fun resource ->
           Effect.named "source.fail" (Effect.sync (fun () -> source := Error "Uh oh!"))
           |> Effect.bind (fun () -> Resource.refresh resource)
           |> Effect.catch (fun (`Refresh_failed _ : [ `Refresh_failed of string ]) ->
                  Effect.unit)
           |> Effect.bind (fun () -> Resource.get resource))
  in
  Alcotest.(check int) "cached value survived failed refresh" 0 (run_ok rt eff)

let test_resource_newer_refresh_wins () =
  with_test_clock @@ fun sw _clock rt ->
  let first_started, first_started_u = Eio.Promise.create () in
  let second_started, second_started_u = Eio.Promise.create () in
  let first_release, first_release_u = Eio.Promise.create () in
  let second_release, second_release_u = Eio.Promise.create () in
  let calls = ref 0 in
  let load =
    Effect.named "resource.load" (Effect.sync (fun () ->
        incr calls;
        match !calls with
        | 1 -> 0
        | 2 ->
            Eio.Promise.resolve first_started_u ();
            Eio.Promise.await first_release
        | 3 ->
            Eio.Promise.resolve second_started_u ();
            Eio.Promise.await second_release
        | n -> Alcotest.failf "unexpected load call %d" n))
  in
  let resource = run_ok rt (Resource.manual load) in
  let first = fork_run sw rt (Resource.refresh resource) in
  Eio.Promise.await first_started;
  let second = fork_run sw rt (Resource.refresh resource) in
  Eio.Promise.await second_started;
  Eio.Promise.resolve second_release_u 2;
  check_exit_ok Alcotest.unit "second refresh" () (Eio.Promise.await second);
  Eio.Promise.resolve first_release_u 1;
  check_exit_ok Alcotest.unit "first refresh" () (Eio.Promise.await first);
  Alcotest.(check int) "newer refresh value" 2
    (run_ok rt (Resource.get resource))

let test_resource_auto_refreshes_on_schedule () =
  with_test_clock @@ fun _sw clock rt ->
  let source = ref 0 in
  let load =
    Effect.named "resource.auto.load" (Effect.sync (fun () ->
        incr source;
        !source))
  in
  let resource =
    run_ok rt (Resource.auto ~load ~schedule:(Schedule.spaced (Duration.ms 5)) ())
  in
  Alcotest.(check int) "initial value" 1 (run_ok rt (Resource.get resource));
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Alcotest.(check int) "first refresh" 2 (run_ok rt (Resource.get resource));
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Alcotest.(check int) "second refresh" 3 (run_ok rt (Resource.get resource))

let test_resource_auto_failed_refresh_keeps_cached_value () =
  with_test_clock @@ fun _sw clock rt ->
  let results = ref [ Ok 1; Error "boom"; Ok 2 ] in
  let load =
    Effect.named "resource.auto.load" (Effect.sync (fun () ->
        match !results with
        | [] -> Ok 999
        | result :: rest ->
            results := rest;
            result))
    |> Effect.bind (function
         | Ok value -> Effect.pure value
         | Error message -> Effect.fail (`Refresh_failed message))
  in
  let errors = ref [] in
  let resource =
    run_ok rt
      (Resource.auto ~load ~schedule:(Schedule.spaced (Duration.ms 5))
         ~on_error:(fun err -> errors := err :: !errors) ())
  in
  Alcotest.(check int) "initial value" 1 (run_ok rt (Resource.get resource));
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Alcotest.(check int) "failed refresh keeps old value" 1
    (run_ok rt (Resource.get resource));
  Alcotest.(check (list string)) "observed refresh error" [ "boom" ]
    (List.map (fun (`Refresh_failed message) -> message) (List.rev !errors));
  (match run_ok rt (Resource.failures resource) with
  | [ Cause.Fail (`Refresh_failed "boom") ] -> ()
  | _ -> Alcotest.fail "expected resource failure sink to record refresh error");
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Alcotest.(check int) "subsequent refresh updates" 2
    (run_ok rt (Resource.get resource))

let test_resource_auto_records_loader_defect_and_continues () =
  with_test_clock @@ fun _sw clock rt ->
  let results = ref [ Ok 1; Error (Failure "loader boom"); Ok 2 ] in
  let load =
    Effect.named "resource.auto.load" (Effect.sync (fun () ->
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
    run_ok rt (Resource.auto ~load ~schedule:(Schedule.spaced (Duration.ms 5)) ())
  in
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Alcotest.(check int) "loader defect keeps old value" 1
    (run_ok rt (Resource.get resource));
  (match run_ok rt (Resource.failures resource) with
  | [ Cause.Die die ] ->
      Alcotest.(check string) "loader defect" "Failure(\"loader boom\")"
        (Printexc.to_string die.exn)
  | _ -> Alcotest.fail "expected loader defect to be recorded");
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Alcotest.(check int) "refresh loop continued" 2
    (run_ok rt (Resource.get resource))

let test_resource_auto_records_on_error_defect_and_continues () =
  with_test_clock @@ fun _sw clock rt ->
  let results = ref [ Ok 1; Error "boom"; Ok 2 ] in
  let load =
    Effect.named "resource.auto.load" (Effect.sync (fun () ->
        match !results with
        | [] -> Ok 999
        | result :: rest ->
            results := rest;
            result))
    |> Effect.bind (function
         | Ok value -> Effect.pure value
         | Error message -> Effect.fail (`Refresh_failed message))
  in
  let resource =
    run_ok rt
      (Resource.auto ~load ~schedule:(Schedule.spaced (Duration.ms 5))
         ~on_error:(fun (`Refresh_failed _) -> failwith "observer boom") ())
  in
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  (match run_ok rt (Resource.failures resource) with
  | [ Cause.Fail (`Refresh_failed "boom"); Cause.Die die ] ->
      Alcotest.(check string) "on_error defect" "Failure(\"observer boom\")"
        (Printexc.to_string die.exn)
  | _ -> Alcotest.fail "expected typed failure and on_error defect");
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Alcotest.(check int) "refresh loop continued" 2
    (run_ok rt (Resource.get resource))
