open Effet

let run_ok rt eff =
  match Runtime.run rt eff with
  | Exit.Ok value -> value
  | Exit.Error _ -> Alcotest.fail "expected Ok"

let check_exit_ok test name expected = function
  | Exit.Ok actual -> Alcotest.check test name expected actual
  | Exit.Error _ -> Alcotest.fail "expected Ok"

let check_exit_error test name expected = function
  | Exit.Ok _ -> Alcotest.fail "expected Error"
  | Exit.Error cause -> Alcotest.check test name expected cause

let with_runtime f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env:() ()
  in
  f rt

module Test_clock = struct
  type sleeper = { deadline_ms : int; resolver : unit Eio.Promise.u }
  type t = { mutable now_ms : int; mutable sleepers : sleeper list }

  let create () = { now_ms = 0; sleepers = [] }

  let wake_due t =
    let due, pending =
      List.partition (fun sleeper -> sleeper.deadline_ms <= t.now_ms) t.sleepers
    in
    t.sleepers <- pending;
    List.iter
      (fun sleeper -> Eio.Promise.resolve sleeper.resolver ())
      due

  let sleep t duration =
    let deadline_ms = t.now_ms + Duration.to_ms duration in
    if deadline_ms <= t.now_ms then ()
    else
      let promise, resolver = Eio.Promise.create () in
      t.sleepers <- { deadline_ms; resolver } :: t.sleepers;
      Eio.Promise.await promise

  let adjust t duration =
    t.now_ms <- t.now_ms + Duration.to_ms duration;
    wake_due t

  let set_time t time_ms =
    t.now_ms <- max 0 time_ms;
    wake_due t

  let sleeper_count t = List.length t.sleepers
end

let yield () = Eio.Fiber.yield ()

let wait_for_sleepers clock expected =
  let attempts = ref 0 in
  while Test_clock.sleeper_count clock < expected && !attempts < 20 do
    incr attempts;
    yield ()
  done

let with_test_clock f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Test_clock.sleep clock) ~env:() ()
  in
  f sw clock rt

let fork_run sw rt eff =
  let promise, resolver = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.resolve resolver (Runtime.run rt eff));
  promise

let dur_ms = Duration.ms
let some_dur = Alcotest.option (Alcotest.testable Duration.pp Duration.equal)
let dur = Alcotest.testable Duration.pp Duration.equal
let string_cause =
  Alcotest.testable (Cause.pp Format.pp_print_string) (Cause.equal String.equal)

let test_pure () =
  let e : (_, _, int) Effect.t = Effect.pure 42 in
  match e with
  | Effect.Pure 42 -> ()
  | _ -> Alcotest.fail "expected Pure 42"

let test_map () =
  let e = Effect.pure 1 |> Effect.map (fun n -> n + 1) in
  match e with
  | Effect.Map (_, _) -> ()
  | _ -> Alcotest.fail "expected Map"

let test_collect_names () =
  let e =
    Effect.concat
      [
        Effect.sync "leaf-a" (fun _ -> ()) |> Effect.map (fun _ -> ());
        Effect.async "leaf-b" (fun _ -> ());
      ]
    |> Effect.named "outer"
  in
  Alcotest.(check (list string))
    "names in pre-order"
    [ "outer"; "leaf-a"; "leaf-b" ]
    (Effect.collect_names e)

let test_duration_constructors () =
  Alcotest.(check dur) "seconds" (Duration.ms 1_000) (Duration.seconds 1);
  Alcotest.(check dur) "minutes" (Duration.seconds 60) (Duration.minutes 1);
  Alcotest.(check dur) "hours" (Duration.minutes 60) (Duration.hours 1);
  Alcotest.(check dur) "days" (Duration.hours 24) (Duration.days 1);
  Alcotest.(check dur) "weeks" (Duration.days 7) (Duration.weeks 1)

let test_duration_ordering () =
  Alcotest.(check int) "lt" (-1)
    (Duration.compare (Duration.ms 1) (Duration.ms 2));
  Alcotest.(check int) "eq" 0
    (Duration.compare (Duration.ms 2) (Duration.ms 2));
  Alcotest.(check int) "gt" 1
    (Duration.compare (Duration.ms 2) (Duration.ms 1));
  Alcotest.(check bool) "between" true
    (Duration.between ~min:(Duration.minutes 59) ~max:(Duration.minutes 61)
       (Duration.hours 1))

let test_duration_algebra () =
  Alcotest.(check dur) "sum" (Duration.minutes 1)
    (Duration.add (Duration.seconds 30) (Duration.seconds 30));
  Alcotest.(check dur) "subtract clamps at zero" Duration.zero
    (Duration.subtract (Duration.seconds 30) (Duration.seconds 40));
  Alcotest.(check dur) "times" (Duration.minutes 1)
    (Duration.times (Duration.seconds 1) 60);
  Alcotest.(check some_dur) "divide" (Some (Duration.seconds 30))
    (Duration.divide (Duration.minutes 1) 2);
  Alcotest.(check some_dur) "divide by zero" None
    (Duration.divide (Duration.minutes 1) 0)

let test_duration_min_max_clamp () =
  Alcotest.(check dur) "max" (Duration.ms 2)
    (Duration.max (Duration.ms 1) (Duration.ms 2));
  Alcotest.(check dur) "min" (Duration.ms 1)
    (Duration.min (Duration.ms 1) (Duration.ms 2));
  Alcotest.(check dur) "clamp lower" (Duration.ms 2)
    (Duration.clamp ~min:(Duration.ms 2) ~max:(Duration.ms 3)
       (Duration.ms 1));
  Alcotest.(check dur) "clamp inside" (Duration.minutes 90)
    (Duration.clamp ~min:(Duration.minutes 60) ~max:(Duration.minutes 120)
       (Duration.minutes 90))

let test_recurs () =
  let s = Schedule.recurs 3 in
  Alcotest.(check some_dur) "0" (Some Duration.zero)
    (Schedule.next_delay s ~step:0);
  Alcotest.(check some_dur) "exhausted" None
    (Schedule.next_delay s ~step:3)

let test_exponential () =
  let s = Schedule.exponential ~factor:2.0 (dur_ms 10) in
  Alcotest.(check some_dur) "step 0" (Some (dur_ms 10))
    (Schedule.next_delay s ~step:0);
  Alcotest.(check some_dur) "step 2 = 40ms" (Some (dur_ms 40))
    (Schedule.next_delay s ~step:2)

let test_spaced_fixed_linear () =
  Alcotest.(check some_dur) "spaced" (Some (Duration.seconds 1))
    (Schedule.next_delay (Schedule.spaced (Duration.seconds 1)) ~step:4);
  Alcotest.(check some_dur) "fixed" (Some (Duration.seconds 1))
    (Schedule.next_delay (Schedule.fixed (Duration.seconds 1)) ~step:4);
  Alcotest.(check some_dur) "linear step 3" (Some (Duration.seconds 7))
    (Schedule.next_delay
       (Schedule.linear ~initial:(Duration.seconds 1)
          ~step:(Duration.seconds 2))
       ~step:3)

let test_schedule_composition () =
  Alcotest.(check some_dur) "both takes max" (Some (Duration.seconds 2))
    (Schedule.next_delay
       (Schedule.both (Schedule.spaced (Duration.seconds 1))
          (Schedule.spaced (Duration.seconds 2)))
       ~step:0);
  Alcotest.(check some_dur) "either takes min" (Some (Duration.seconds 1))
    (Schedule.next_delay
       (Schedule.either (Schedule.spaced (Duration.seconds 1))
          (Schedule.spaced (Duration.seconds 2)))
       ~step:0);
  Alcotest.(check some_dur) "and_then falls through" (Some (Duration.seconds 1))
    (Schedule.next_delay
       (Schedule.and_then (Schedule.recurs 1)
          (Schedule.spaced (Duration.seconds 1)))
       ~step:1)

let test_effect_map_bind_tap_runtime () =
  with_runtime @@ fun rt ->
  let observed = ref [] in
  let eff =
    Effect.pure 1
    |> Effect.map (fun n -> n + 1)
    |> Effect.bind (fun n -> Effect.pure (n * 2))
    |> Effect.tap (fun n ->
           Effect.sync "tap" (fun () -> observed := n :: !observed))
    |> Effect.map (fun n -> n + 1)
  in
  Alcotest.(check int) "value" 5 (run_ok rt eff);
  Alcotest.(check (list int)) "tap saw pre-map value" [ 4 ] !observed

let test_effect_catch_success_and_failure () =
  with_runtime @@ fun rt ->
  let success =
    Effect.pure 1
    |> Effect.catch (fun (`Unexpected : [ `Unexpected ]) ->
           Effect.fail `Handler_ran)
  in
  let failure =
    Effect.fail `First
    |> Effect.catch (fun (`First : [ `First ]) -> Effect.fail `Second)
    |> Effect.catch (fun (`Second : [ `Second ]) -> Effect.pure "recovered")
  in
  Alcotest.(check int) "success bypasses catch" 1 (run_ok rt success);
  Alcotest.(check string) "failure recovers" "recovered" (run_ok rt failure)

let test_effect_tap_error_observes_and_rethrows () =
  with_runtime @@ fun rt ->
  let observed = ref false in
  let eff =
    Effect.fail `Boom
    |> Effect.tap_error (fun (`Boom : [ `Boom ]) -> observed := true)
    |> Effect.catch (fun (`Boom : [ `Boom ]) -> Effect.pure "recovered")
  in
  Alcotest.(check string) "recovered" "recovered" (run_ok rt eff);
  Alcotest.(check bool) "observed" true !observed

let test_runtime_exit_fail_die_interrupt () =
  with_runtime @@ fun rt ->
  let die = Failure "boom" in
  let fail_exit = Runtime.run rt (Effect.fail "bad") in
  let die_exit = Runtime.run rt (Effect.sync "die" (fun () -> raise die)) in
  let interrupt_exit =
    Runtime.run rt
      (Effect.sync "interrupt" (fun () ->
           raise (Eio.Cancel.Cancelled (Failure "cancel"))))
  in
  check_exit_error string_cause "typed failure" (Cause.Fail "bad") fail_exit;
  (match die_exit with
  | Exit.Error (Cause.Die exn) ->
      Alcotest.(check bool) "same exception" true (exn == die)
  | _ -> Alcotest.fail "expected Die");
  (match interrupt_exit with
  | Exit.Error Cause.Interrupt -> ()
  | _ -> Alcotest.fail "expected Interrupt")

let test_effect_catch_does_not_catch_interrupt () =
  with_runtime @@ fun rt ->
  let eff =
    Effect.sync "interrupt" (fun () ->
        raise (Eio.Cancel.Cancelled (Failure "cancel")))
    |> Effect.catch (fun (_ : string) -> Effect.pure "caught")
  in
  match Runtime.run rt eff with
  | Exit.Error Cause.Interrupt -> ()
  | _ -> Alcotest.fail "expected Interrupt"

let test_effect_retry_does_not_retry_interrupt () =
  with_runtime @@ fun rt ->
  let attempts = ref 0 in
  let attempt =
    Effect.sync "interrupt" (fun () ->
        incr attempts;
        raise (Eio.Cancel.Cancelled (Failure "cancel")))
  in
  let eff = Effect.retry (Schedule.recurs 3) (fun (_ : string) -> true) attempt in
  (match Runtime.run rt eff with
  | Exit.Error Cause.Interrupt -> ()
  | _ -> Alcotest.fail "expected Interrupt");
  Alcotest.(check int) "not retried" 1 !attempts

let test_acquire_release () =
  with_runtime @@ fun rt ->
  let trail = ref [] in
  let mark name = Effect.sync name (fun () -> trail := name :: !trail) in
  let eff =
    Effect.scoped
      (Effect.acquire_release
         ~acquire:(mark "acquired" |> Effect.map (fun () -> 1))
         ~release:(fun _ -> mark "released")
      |> Effect.bind (fun _ -> mark "body"))
  in
  run_ok rt eff;
  Alcotest.(check (list string))
    "ordering" [ "acquired"; "body"; "released" ] (List.rev !trail)

let test_acquire_release_on_failure () =
  with_runtime @@ fun rt ->
  let trail = ref [] in
  let mark name = Effect.sync name (fun () -> trail := name :: !trail) in
  let eff =
    Effect.scoped
      (Effect.acquire_release ~acquire:(mark "acq") ~release:(fun () ->
           mark "rel")
      |> Effect.bind (fun () -> Effect.fail `Boom)
      |> Effect.catch (fun (`Boom : [ `Boom ]) -> mark "caught"))
  in
  run_ok rt eff;
  Alcotest.(check (list string))
    "release after recovered body failure"
    [ "acq"; "caught"; "rel" ] (List.rev !trail)

let test_effect_timeout_uses_virtual_clock () =
  with_test_clock @@ fun sw clock rt ->
  let eff =
    Effect.pure "done"
    |> Effect.delay (Duration.seconds 10)
    |> Effect.timeout (Duration.seconds 5)
    |> Effect.catch (fun (`Timeout : [ `Timeout ]) -> Effect.pure "timeout")
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.seconds 5);
  check_exit_ok Alcotest.string "timed out" "timeout"
    (Eio.Promise.await promise)

let test_effect_timeout_allows_fast_success () =
  with_test_clock @@ fun sw clock rt ->
  let eff =
    Effect.pure "done"
    |> Effect.delay (Duration.seconds 2)
    |> Effect.timeout (Duration.seconds 5)
    |> Effect.catch (fun (`Timeout : [ `Timeout ]) -> Effect.pure "timeout")
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.seconds 2);
  check_exit_ok Alcotest.string "completed" "done"
    (Eio.Promise.await promise)

let test_effect_race_ignores_early_failure_until_success () =
  with_test_clock @@ fun sw clock rt ->
  let delayed_success ms value =
    Effect.pure value |> Effect.delay (Duration.ms ms)
  in
  let eff =
    Effect.race
      [
        Effect.fail `Boom |> Effect.delay Duration.zero;
        delayed_success 200 200;
        delayed_success 100 100;
      ]
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 2;
  Alcotest.(check int) "race sleepers registered" 2
    (Test_clock.sleeper_count clock);
  Test_clock.adjust clock (Duration.ms 100);
  check_exit_ok Alcotest.int "first success wins" 100
    (Eio.Promise.await promise)

let test_effect_race_all_failures_returns_both_causes () =
  with_test_clock @@ fun sw clock rt ->
  let delayed_failure ms error =
    Effect.fail error |> Effect.delay (Duration.ms ms)
  in
  let eff = Effect.race [ delayed_failure 0 "first"; delayed_failure 10 "second" ] in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 10);
  check_exit_error string_cause "failures combined"
    (Cause.Both (Cause.Fail "first", Cause.Fail "second"))
    (Eio.Promise.await promise)

let test_effect_repeat_schedule () =
  with_runtime @@ fun rt ->
  let ticks = ref 0 in
  let tick = Effect.sync "tick" (fun () -> incr ticks) in
  run_ok rt (Effect.repeat (Schedule.recurs 3) tick);
  Alcotest.(check int) "initial run plus three repeats" 4 !ticks

let test_effect_repeat_schedule_uses_virtual_delays () =
  with_test_clock @@ fun sw clock rt ->
  let ticks = ref 0 in
  let schedule =
    Schedule.both (Schedule.recurs 3) (Schedule.spaced (Duration.ms 5))
  in
  let promise =
    fork_run sw rt (Effect.sync "tick" (fun () -> incr ticks) |> Effect.repeat schedule)
  in
  yield ();
  Alcotest.(check int) "initial tick" 1 !ticks;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Alcotest.(check int) "second tick" 2 !ticks;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Alcotest.(check int) "third tick" 3 !ticks;
  Test_clock.adjust clock (Duration.ms 5);
  check_exit_ok Alcotest.unit "repeat done" () (Eio.Promise.await promise);
  Alcotest.(check int) "three delayed repeats" 4 !ticks

let test_effect_retry_schedule_until_success () =
  with_runtime @@ fun rt ->
  let attempts = ref 0 in
  let attempt =
    Effect.sync "attempt" (fun () ->
        incr attempts;
        !attempts)
    |> Effect.bind (fun n ->
           if n < 3 then Effect.fail (`Again n) else Effect.pure n)
  in
  Alcotest.(check int) "succeeded" 3
    (run_ok rt (Effect.retry (Schedule.recurs 5) (fun (`Again _) -> true) attempt))

let test_effect_retry_schedule_uses_virtual_delays () =
  with_test_clock @@ fun sw clock rt ->
  let attempts = ref 0 in
  let schedule =
    Schedule.both (Schedule.recurs 5) (Schedule.spaced (Duration.ms 5))
  in
  let attempt =
    Effect.sync "attempt" (fun () ->
        incr attempts;
        !attempts)
    |> Effect.bind (fun n ->
           if n < 3 then Effect.fail (`Again n) else Effect.pure n)
  in
  let promise =
    fork_run sw rt (Effect.retry schedule (fun (`Again _) -> true) attempt)
  in
  yield ();
  Alcotest.(check int) "first attempt before delay" 1 !attempts;
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  check_exit_ok Alcotest.int "succeeded on delayed third attempt" 3
    (Eio.Promise.await promise)

let test_effect_detach_does_not_block_parent () =
  with_test_clock @@ fun _sw clock rt ->
  let parent_done = ref false in
  let child_done = ref false in
  let child =
    Effect.sync "child" (fun () -> child_done := true)
    |> Effect.delay (Duration.ms 10)
  in
  let parent =
    Effect.detach child
    |> Effect.bind (fun () ->
           Effect.sync "parent" (fun () -> parent_done := true))
  in
  run_ok rt parent;
  Alcotest.(check bool) "parent completed" true !parent_done;
  Alcotest.(check bool) "child is still sleeping" false !child_done;
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 10);
  Runtime.drain rt;
  Alcotest.(check bool) "detached child completed" true !child_done

let test_effect_detach_child_failure_is_not_parent_failure () =
  with_runtime @@ fun rt ->
  let parent_done = ref false in
  let eff =
    Effect.detach (Effect.fail `Detached_boom)
    |> Effect.bind (fun () ->
           Effect.sync "parent" (fun () -> parent_done := true))
  in
  run_ok rt eff;
  Runtime.drain rt;
  Alcotest.(check bool) "parent completed" true !parent_done

let test_effect_uninterruptible_defers_race_cancellation () =
  with_test_clock @@ fun sw clock rt ->
  let slow_completed = ref false in
  let slow =
    Effect.sync "slow.done" (fun () ->
        slow_completed := true;
        "slow")
    |> Effect.delay (Duration.ms 10)
    |> Effect.uninterruptible
  in
  let promise = fork_run sw rt (Effect.race [ slow; Effect.pure "fast" ]) in
  wait_for_sleepers clock 1;
  yield ();
  Alcotest.(check bool) "race waits for protected loser" false
    (Eio.Promise.is_resolved promise);
  Test_clock.adjust clock (Duration.ms 10);
  check_exit_ok Alcotest.string "winner preserved" "fast"
    (Eio.Promise.await promise);
  Alcotest.(check bool) "protected loser completed" true !slow_completed

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

let test_scope_finalizers_run_in_parallel () =
  with_test_clock @@ fun sw clock rt ->
  let released = ref 0 in
  let resource =
    Effect.acquire_release ~acquire:Effect.unit ~release:(fun () ->
        Effect.sync "release" (fun () -> incr released)
        |> Effect.delay (Duration.seconds 1))
  in
  let promise =
    fork_run sw rt (Effect.scoped (Effect.concat [ resource; resource; resource ]))
  in
  yield ();
  wait_for_sleepers clock 3;
  Test_clock.adjust clock (Duration.seconds 1);
  check_exit_ok Alcotest.unit "scope done" () (Eio.Promise.await promise);
  Alcotest.(check int) "all finalizers released" 3 !released

let test_resource_manual_refresh () =
  with_runtime @@ fun rt ->
  let source = ref 0 in
  let load = Effect.sync "resource.load" (fun () -> !source) in
  let eff =
    Resource.manual load
    |> Effect.bind (fun resource ->
           Resource.get resource
           |> Effect.bind (fun initial ->
                  Effect.sync "source.set" (fun () -> source := 1)
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
    Effect.sync "resource.load" (fun () -> !source)
    |> Effect.bind (function
         | Ok value -> Effect.pure value
         | Error message -> Effect.fail (`Refresh_failed message))
  in
  let eff =
    Resource.manual load
    |> Effect.bind (fun resource ->
           Effect.sync "source.fail" (fun () -> source := Error "Uh oh!")
           |> Effect.bind (fun () -> Resource.refresh resource)
           |> Effect.catch (fun (`Refresh_failed _ : [ `Refresh_failed of string ]) ->
                  Effect.unit)
           |> Effect.bind (fun () -> Resource.get resource))
  in
  Alcotest.(check int) "cached value survived failed refresh" 0 (run_ok rt eff)

let () =
  Alcotest.run "effet"
    [
      ( "Effect",
        [
          Alcotest.test_case "Pure" `Quick test_pure;
          Alcotest.test_case "Map" `Quick test_map;
          Alcotest.test_case "collect_names" `Quick test_collect_names;
          Alcotest.test_case "map bind tap runtime" `Quick
            test_effect_map_bind_tap_runtime;
          Alcotest.test_case "catch success and failure" `Quick
            test_effect_catch_success_and_failure;
          Alcotest.test_case "tap_error observes and rethrows" `Quick
            test_effect_tap_error_observes_and_rethrows;
          Alcotest.test_case "runtime exit fail die interrupt" `Quick
            test_runtime_exit_fail_die_interrupt;
          Alcotest.test_case "catch does not catch interrupt" `Quick
            test_effect_catch_does_not_catch_interrupt;
          Alcotest.test_case "acquire release" `Quick test_acquire_release;
          Alcotest.test_case "acquire release on failure" `Quick
            test_acquire_release_on_failure;
          Alcotest.test_case "timeout uses virtual clock" `Quick
            test_effect_timeout_uses_virtual_clock;
          Alcotest.test_case "timeout allows fast success" `Quick
            test_effect_timeout_allows_fast_success;
          Alcotest.test_case "race ignores early failure until success" `Quick
            test_effect_race_ignores_early_failure_until_success;
          Alcotest.test_case "race all failures returns both causes" `Quick
            test_effect_race_all_failures_returns_both_causes;
          Alcotest.test_case "repeat schedule" `Quick test_effect_repeat_schedule;
          Alcotest.test_case "repeat schedule uses virtual delays" `Quick
            test_effect_repeat_schedule_uses_virtual_delays;
          Alcotest.test_case "retry schedule until success" `Quick
            test_effect_retry_schedule_until_success;
          Alcotest.test_case "retry schedule uses virtual delays" `Quick
            test_effect_retry_schedule_uses_virtual_delays;
          Alcotest.test_case "retry does not retry interrupt" `Quick
            test_effect_retry_does_not_retry_interrupt;
          Alcotest.test_case "detach does not block parent" `Quick
            test_effect_detach_does_not_block_parent;
          Alcotest.test_case "detach child failure is not parent failure" `Quick
            test_effect_detach_child_failure_is_not_parent_failure;
          Alcotest.test_case "uninterruptible defers race cancellation" `Quick
            test_effect_uninterruptible_defers_race_cancellation;
        ] );
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
      ( "Duration",
        [
          Alcotest.test_case "constructors" `Quick test_duration_constructors;
          Alcotest.test_case "ordering" `Quick test_duration_ordering;
          Alcotest.test_case "algebra" `Quick test_duration_algebra;
          Alcotest.test_case "min max clamp" `Quick test_duration_min_max_clamp;
        ] );
      ( "Schedule",
        [
          Alcotest.test_case "recurs" `Quick test_recurs;
          Alcotest.test_case "exponential" `Quick test_exponential;
          Alcotest.test_case "spaced fixed linear" `Quick
            test_spaced_fixed_linear;
          Alcotest.test_case "composition" `Quick test_schedule_composition;
        ] );
      ( "Scope",
        [
          Alcotest.test_case "finalizers run in parallel" `Quick
            test_scope_finalizers_run_in_parallel;
        ] );
      ( "Resource",
        [
          Alcotest.test_case "manual refresh" `Quick test_resource_manual_refresh;
          Alcotest.test_case "failed refresh keeps cached value" `Quick
            test_resource_failed_refresh_keeps_cached_value;
        ] );
    ]
