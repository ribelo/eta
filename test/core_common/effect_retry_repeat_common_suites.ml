module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  open Eta

  let pp_hidden ppf _ = Format.pp_print_string ppf "<effect>"

  let runtime_interrupt_effect () =
    Effect.Expert.make ~leaf_name:"test.interrupt" @@ fun context ->
    let contract = Effect.Expert.contract context in
    contract.Eta.Runtime_contract.cancel_sub @@ fun cancel_context ->
    contract.Eta.Runtime_contract.cancel cancel_context Exit;
    contract.Eta.Runtime_contract.await_cancel ()

  let run_ok rt eff =
    match B.run rt eff with
    | Exit.Ok value -> value
    | Exit.Error cause ->
        Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause

  let effect_error_cause cause =
    Effect.Expert.make ~leaf_name:"test.error-cause" @@ fun _context ->
    Exit.Error cause

  let check_exit_ok test name expected = function
    | Exit.Ok actual -> Alcotest.check test name expected actual
    | Exit.Error cause ->
        Alcotest.failf "%s: expected Ok, got %a" name (Cause.pp pp_hidden)
          cause

  let check_exit_succeeded name = function
    | Exit.Ok _ -> ()
    | Exit.Error cause ->
        Alcotest.failf "%s: expected Ok, got %a" name (Cause.pp pp_hidden)
          cause

  let wait_for_sleepers clock expected =
    let rec loop attempts =
      if B.sleeper_count clock >= expected then ()
      else if attempts = 0 then
        Alcotest.failf "expected at least %d sleepers, got %d" expected
          (B.sleeper_count clock)
      else (
        B.yield ();
        loop (attempts - 1))
    in
    loop 20

  let wait_until pred =
    let rec loop attempts =
      if pred () then ()
      else if attempts = 0 then Alcotest.fail "condition did not become true"
      else (
        B.yield ();
        loop (attempts - 1))
    in
    loop 20

  let drive_clock_until_resolved ?(steps = 200) clock promise =
    let rec loop remaining =
      if B.is_resolved promise then ()
      else if remaining = 0 then Alcotest.fail "promise did not resolve"
      else (
        if B.sleeper_count clock > 0 then B.adjust_clock clock (Duration.ms 1)
        else B.yield ();
        loop (remaining - 1))
    in
    loop steps

  let expect_interrupted label = function
    | `Cancelled -> ()
    | `Returned (Exit.Error (Cause.Interrupt _)) -> ()
    | `Returned (Exit.Ok _) ->
        Alcotest.failf "%s: expected interruption, got Ok" label
    | `Returned (Exit.Error cause) ->
        Alcotest.failf "%s: expected interruption, got %a" label
          (Cause.pp pp_hidden) cause

  let test_effect_retry_does_nothing_on_initial_success () =
    B.with_runtime @@ fun _ctx rt ->
    let attempts = ref 0 in
    let attempt =
      Effect.sync (fun () ->
          incr attempts;
          "ok")
    in
    Alcotest.(check string) "result" "ok"
      (run_ok rt
         (Effect.retry ~schedule:(Schedule.recurs 3) ~while_:(fun (_ : string) -> true) attempt));
    Alcotest.(check int) "one attempt" 1 !attempts

  let test_effect_retry_stops_when_predicate_rejects_typed_error () =
    B.with_runtime @@ fun _ctx rt ->
    let attempts = ref 0 in
    let attempt =
      Effect.sync (fun () -> incr attempts)
      |> Effect.bind (fun () -> Effect.fail (`Reject !attempts))
    in
    let eff =
      Effect.retry ~schedule:(Schedule.recurs 5) ~while_:(fun (`Reject n) -> n < 2) attempt
    in
    (match B.run rt eff with
    | Exit.Error (Cause.Fail (`Reject 2)) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected rejected typed failure, got %a"
          (Cause.pp (fun fmt (`Reject n) -> Format.fprintf fmt "Reject %d" n))
          cause
    | Exit.Ok _ -> Alcotest.fail "expected rejected typed failure");
    Alcotest.(check int) "initial plus one retry" 2 !attempts

  let test_effect_retry_recurs_attempts_initial_plus_retries () =
    B.with_runtime @@ fun _ctx rt ->
    let attempts = ref 0 in
    let attempt =
      Effect.sync (fun () -> incr attempts)
      |> Effect.bind (fun () -> Effect.fail `Again)
    in
    (match
       B.run rt (Effect.retry ~schedule:(Schedule.recurs 3) ~while_:(fun `Again -> true) attempt)
     with
    | Exit.Error (Cause.Fail `Again) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected final typed failure, got %a"
          (Cause.pp (fun fmt `Again -> Format.pp_print_string fmt "Again"))
          cause
    | Exit.Ok _ -> Alcotest.fail "expected final typed failure");
    Alcotest.(check int) "initial plus three retries" 4 !attempts

  let test_effect_retry_does_not_catch_defects () =
    B.with_runtime @@ fun _ctx rt ->
    let attempts = ref 0 in
    let attempt =
      Effect.sync (fun () ->
          incr attempts;
          failwith "retry defect")
    in
    (match
       B.run rt
         (Effect.retry ~schedule:(Schedule.recurs 3) ~while_:(fun (_ : string) -> true) attempt)
     with
    | Exit.Error (Cause.Die _) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected defect, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected defect");
    Alcotest.(check int) "not retried" 1 !attempts

  let test_effect_retry_does_not_retry_cancellation () =
    B.with_runtime @@ fun ctx rt ->
    let attempts = ref 0 in
    let entered, entered_resolver = B.create_promise () in
    let attempt : (unit, string) Effect.t =
      Effect.sync (fun () ->
          incr attempts;
          B.resolve entered_resolver ())
      |> Effect.bind (fun () -> B.await_cancel_effect ())
    in
    let eff =
      Effect.retry ~schedule:(Schedule.recurs 3) ~while_:(fun (_ : string) -> true) attempt
    in
    let fiber = B.fork_run_cancelable ctx rt eff in
    ignore (B.await entered : unit);
    B.cancel_fiber fiber;
    expect_interrupted "retry" (B.await_cancelable fiber);
    Alcotest.(check int) "not retried" 1 !attempts

  let test_effect_retry_does_not_retry_interrupt () =
    B.with_runtime @@ fun _ctx rt ->
    let attempts = ref 0 in
    let attempt =
      Effect.named "interrupt"
        (Effect.sync (fun () -> incr attempts)
        |> Effect.bind (fun () -> runtime_interrupt_effect ()))
    in
    let eff =
      Effect.retry ~schedule:(Schedule.recurs 3) ~while_:(fun (_ : string) -> true) attempt
    in
    (match B.run rt eff with
    | Exit.Error (Cause.Interrupt None) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected Interrupt, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected Interrupt");
    Alcotest.(check int) "not retried" 1 !attempts

  let test_effect_repeat_schedule () =
    B.with_runtime @@ fun _ctx rt ->
    let ticks = ref 0 in
    let tick = Effect.named "tick" (Effect.sync (fun () -> incr ticks)) in
    ignore (run_ok rt (Effect.repeat ~schedule:(Schedule.recurs 3) tick) : int);
    Alcotest.(check int) "initial run plus three repeats" 4 !ticks

  let test_effect_repeat_recurs_zero_runs_body_once () =
    B.with_runtime @@ fun _ctx rt ->
    let ticks = ref 0 in
    ignore
      (run_ok rt
         (Effect.repeat ~schedule:(Schedule.recurs 0) (Effect.sync (fun () -> incr ticks)))
        : int);
    Alcotest.(check int) "initial run only" 1 !ticks

  let test_effect_repeat_schedule_uses_virtual_delays () =
    B.with_test_clock @@ fun ctx clock rt ->
    let ticks = ref 0 in
    let schedule =
      Schedule.both (Schedule.recurs 3) (Schedule.spaced (Duration.ms 5))
    in
    let promise =
      B.fork_run ctx rt
        (Effect.named "tick" (Effect.sync (fun () -> incr ticks))
        |> Effect.repeat ~schedule:schedule)
    in
    B.yield ();
    Alcotest.(check int) "initial tick" 1 !ticks;
    B.adjust_clock clock (Duration.ms 5);
    B.yield ();
    Alcotest.(check int) "second tick" 2 !ticks;
    B.adjust_clock clock (Duration.ms 5);
    B.yield ();
    Alcotest.(check int) "third tick" 3 !ticks;
    B.adjust_clock clock (Duration.ms 5);
    check_exit_ok
      Alcotest.(pair int int)
      "repeat done" (3, 3) (B.await promise);
    Alcotest.(check int) "three delayed repeats" 4 !ticks

  let repeat_start_times schedule body_duration =
    B.with_test_clock @@ fun ctx clock rt ->
    let starts = ref [] in
    let body =
      Effect.now
      |> Effect.bind (fun now_ms ->
             Effect.sync (fun () -> starts := now_ms :: !starts))
      |> Effect.bind (fun () -> Effect.sleep body_duration)
    in
    let promise = B.fork_run ctx rt (Effect.repeat ~schedule:schedule body) in
    drive_clock_until_resolved clock promise;
    check_exit_succeeded "repeat done" (B.await promise);
    List.rev !starts

  let test_effect_repeat_fixed_cadence_differs_from_spaced () =
    let fixed_starts =
      repeat_start_times
        (Schedule.both (Schedule.recurs 3) (Schedule.fixed (Duration.ms 10)))
        (Duration.ms 5)
    in
    let spaced_starts =
      repeat_start_times
        (Schedule.both (Schedule.recurs 3) (Schedule.spaced (Duration.ms 10)))
        (Duration.ms 5)
    in
    Alcotest.(check (list int))
      "fixed keeps cadence after first scheduled delay" [ 0; 15; 25; 35 ]
      fixed_starts;
    Alcotest.(check (list int))
      "spaced waits after each completed action" [ 0; 15; 30; 45 ]
      spaced_starts

  let test_effect_repeat_fixed_overrun_has_no_pileup () =
    let starts =
      repeat_start_times
        (Schedule.both (Schedule.recurs 3) (Schedule.fixed (Duration.ms 10)))
        (Duration.ms 15)
    in
    Alcotest.(check (list int))
      "overrun runs next recurrence immediately without replaying missed slots"
      [ 0; 25; 40; 55 ] starts

  let test_effect_repeat_timeout_interrupts_loop () =
    B.with_test_clock @@ fun ctx clock rt ->
    let ticks = ref 0 in
    let eff =
      Effect.repeat ~schedule:(Schedule.spaced (Duration.ms 10)) (Effect.sync (fun () -> incr ticks))
      |> Effect.timeout_as (Duration.ms 25) ~on_timeout:`Timed_out
    in
    let promise = B.fork_run ctx rt eff in
    wait_until (fun () -> !ticks = 1);
    Alcotest.(check int) "initial run" 1 !ticks;
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 10);
    B.yield ();
    Alcotest.(check int) "first repeat" 2 !ticks;
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 10);
    B.yield ();
    Alcotest.(check int) "second repeat" 3 !ticks;
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 5);
    match B.await promise with
    | Exit.Error (Cause.Fail `Timed_out) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected timeout, got %a"
          (Cause.pp (fun fmt `Timed_out ->
               Format.pp_print_string fmt "Timed_out"))
          cause
    | Exit.Ok _ -> Alcotest.fail "expected timeout"

  let test_effect_forever_repeats_until_timeout () =
    B.with_test_clock @@ fun ctx clock rt ->
    let ticks = ref 0 in
    let source =
      Effect.sync (fun () -> incr ticks)
      |> Effect.bind (fun () -> Effect.sleep (Duration.ms 10))
    in
    let eff =
      Effect.forever source
      |> Effect.timeout_as (Duration.ms 25) ~on_timeout:`Timed_out
    in
    let promise = B.fork_run ctx rt eff in
    wait_until (fun () -> !ticks = 1);
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 10);
    wait_until (fun () -> !ticks = 2);
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 10);
    wait_until (fun () -> !ticks = 3);
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 5);
    match B.await promise with
    | Exit.Error (Cause.Fail `Timed_out) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected timeout, got %a"
          (Cause.pp (fun fmt `Timed_out ->
               Format.pp_print_string fmt "Timed_out"))
          cause
    | Exit.Ok _ -> Alcotest.fail "forever unexpectedly succeeded"

  let test_effect_forever_stops_on_typed_failure () =
    B.with_runtime @@ fun _ctx rt ->
    let attempts = ref 0 in
    let source =
      Effect.sync (fun () -> incr attempts)
      |> Effect.bind (fun () ->
             if !attempts < 3 then Effect.pure "ok" else Effect.fail `Boom)
    in
    (match B.run rt (Effect.forever source) with
    | Exit.Error (Cause.Fail `Boom) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected typed failure, got %a"
          (Cause.pp (fun fmt `Boom -> Format.pp_print_string fmt "Boom"))
          cause
    | Exit.Ok _ -> Alcotest.fail "forever unexpectedly succeeded");
    Alcotest.(check int) "stopped after failure" 3 !attempts

  let test_effect_forever_stops_on_defect () =
    B.with_runtime @@ fun _ctx rt ->
    let attempts = ref 0 in
    let source =
      Effect.sync (fun () ->
          incr attempts;
          failwith "forever defect")
    in
    (match B.run rt (Effect.forever source) with
    | Exit.Error (Cause.Die _) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected defect, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "forever unexpectedly succeeded");
    Alcotest.(check int) "not repeated after defect" 1 !attempts

  let test_effect_forever_stops_on_finalizer_diagnostic () =
    B.with_runtime @@ fun _ctx rt ->
    let attempts = ref 0 in
    let source =
      Effect.scoped
        (Effect.acquire_use_release ~acquire:Effect.unit
           ~release:(fun () -> Effect.fail "release")
           (fun () -> Effect.sync (fun () -> incr attempts)))
    in
    (match B.run rt (Effect.forever source) with
    | Exit.Error (Cause.Finalizer (Cause.Finalizer.Fail "<typed failure>")) ->
        ()
    | Exit.Error cause ->
        Alcotest.failf "expected finalizer diagnostic, got %a"
          (Cause.pp Format.pp_print_string)
          cause
    | Exit.Ok _ -> Alcotest.fail "forever unexpectedly succeeded");
    Alcotest.(check int) "not repeated after finalizer diagnostic" 1 !attempts

  let test_effect_retry_schedule_until_success () =
    B.with_runtime @@ fun _ctx rt ->
    let attempts = ref 0 in
    let attempt =
      Effect.named "attempt"
        (Effect.sync (fun () ->
             incr attempts;
             !attempts))
      |> Effect.bind (fun n ->
             if n < 3 then Effect.fail (`Again n) else Effect.pure n)
    in
    Alcotest.(check int) "succeeded" 3
      (run_ok rt
         (Effect.retry ~schedule:(Schedule.recurs 5) ~while_:(fun (`Again _) -> true) attempt))

  let test_effect_retry_schedule_uses_virtual_delays () =
    B.with_test_clock @@ fun ctx clock rt ->
    let attempts = ref 0 in
    let schedule =
      Schedule.both (Schedule.recurs 5) (Schedule.spaced (Duration.ms 5))
    in
    let attempt =
      Effect.named "attempt"
        (Effect.sync (fun () ->
             incr attempts;
             !attempts))
      |> Effect.bind (fun n ->
             if n < 3 then Effect.fail (`Again n) else Effect.pure n)
    in
    let promise =
      B.fork_run ctx rt (Effect.retry ~schedule:schedule ~while_:(fun (`Again _) -> true) attempt)
    in
    B.yield ();
    Alcotest.(check int) "first attempt before delay" 1 !attempts;
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    check_exit_ok Alcotest.int "succeeded on delayed third attempt" 3
      (B.await promise)

  let test_schedule_tap_input_runs_before_inner_step () =
    B.with_runtime @@ fun _ctx rt ->
    let events = ref [] in
    let attempts = ref 0 in
    let record event = Effect.sync (fun () -> events := event :: !events) in
    let schedule =
      Schedule.recurs 1
      |> Schedule.tap_output (fun output -> record (`Output output))
      |> Schedule.tap_input (fun (`Again n) -> record (`Input n))
    in
    let attempt =
      Effect.sync (fun () ->
          incr attempts;
          events := `Attempt !attempts :: !events;
          !attempts)
      |> Effect.bind (fun n ->
             if n = 1 then Effect.fail (`Again n) else Effect.pure n)
    in
    Alcotest.(check int) "retry result" 2
      (run_ok rt (Effect.retry ~schedule:schedule ~while_:(fun (`Again _) -> true) attempt));
    Alcotest.(check (list (testable pp_hidden ( = ))))
      "tap input before inner output"
      [ `Attempt 1; `Input 1; `Output 0; `Attempt 2 ]
      (List.rev !events)

  let test_schedule_tap_output_runs_on_continue_and_done () =
    B.with_runtime @@ fun _ctx rt ->
    let outputs = ref [] in
    let attempts = ref 0 in
    let schedule =
      Schedule.recurs 1
      |> Schedule.tap_output (fun output ->
             Effect.sync (fun () -> outputs := output :: !outputs))
    in
    let attempt =
      Effect.sync (fun () -> incr attempts)
      |> Effect.bind (fun () -> Effect.fail `Again)
    in
    (match B.run rt (Effect.retry ~schedule:schedule ~while_:(fun `Again -> true) attempt) with
    | Exit.Error (Cause.Fail `Again) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected final typed failure, got %a"
          (Cause.pp (fun fmt `Again -> Format.pp_print_string fmt "Again"))
          cause
    | Exit.Ok _ -> Alcotest.fail "expected final typed failure");
    Alcotest.(check int) "initial plus retry" 2 !attempts;
    Alcotest.(check (list int)) "continue and done outputs" [ 0; 1 ]
      (List.rev !outputs)

  let test_schedule_tap_failure_stops_retry_without_sleep () =
    B.with_test_clock @@ fun _ctx clock rt ->
    let attempts = ref 0 in
    let schedule =
      Schedule.spaced (Duration.ms 10)
      |> Schedule.tap_input (fun _ -> Effect.fail `Tap_failed)
    in
    let attempt : (unit, [ `Again | `Tap_failed ]) Effect.t =
      Effect.sync (fun () -> incr attempts)
      |> Effect.bind (fun () -> Effect.fail `Again)
    in
    (match
       B.run rt
         (Effect.retry ~schedule:schedule ~while_:(function `Again -> true | `Tap_failed -> false) attempt)
     with
    | Exit.Error (Cause.Fail `Tap_failed) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected tap failure, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected tap failure");
    Alcotest.(check int) "source attempted once" 1 !attempts;
    Alcotest.(check int) "no retry sleep scheduled" 0 (B.sleeper_count clock)

  let test_schedule_tap_failure_stops_repeat () =
    B.with_runtime @@ fun _ctx rt ->
    let ticks = ref 0 in
    let schedule =
      Schedule.recurs 1
      |> Schedule.tap_output (fun _ -> Effect.fail `Tap_failed)
    in
    let body =
      Effect.sync (fun () ->
          incr ticks;
          ())
    in
    (match B.run rt (Effect.repeat ~schedule:schedule body) with
    | Exit.Error (Cause.Fail `Tap_failed) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected tap failure, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected tap failure");
    Alcotest.(check int) "body ran before failed schedule tap" 1 !ticks

  let test_schedule_tap_callback_exception_is_defect () =
    B.with_runtime @@ fun _ctx rt ->
    let attempts = ref 0 in
    let defect = Failure "tap callback boom" in
    let schedule =
      Schedule.recurs 1
      |> Schedule.tap_input (fun _ -> raise defect)
    in
    let attempt =
      Effect.sync (fun () -> incr attempts)
      |> Effect.bind (fun () -> Effect.fail `Again)
    in
    (match B.run rt (Effect.retry ~schedule:schedule ~while_:(fun `Again -> true) attempt) with
    | Exit.Error (Cause.Die die) when die.exn == defect -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected tap callback defect, got %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected tap callback defect");
    Alcotest.(check int) "source attempted once" 1 !attempts

  let test_schedule_tap_interruption_is_preserved () =
    B.with_runtime @@ fun _ctx rt ->
    let attempts = ref 0 in
    let schedule =
      Schedule.recurs 1
      |> Schedule.tap_input (fun _ -> runtime_interrupt_effect ())
    in
    let attempt =
      Effect.sync (fun () -> incr attempts)
      |> Effect.bind (fun () -> Effect.fail `Again)
    in
    (match B.run rt (Effect.retry ~schedule:schedule ~while_:(fun `Again -> true) attempt) with
    | Exit.Error (Cause.Interrupt None) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected tap interruption, got %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected tap interruption");
    Alcotest.(check int) "source attempted once" 1 !attempts

  let test_effect_retry_fibonacci_schedule_uses_virtual_delays () =
    B.with_test_clock @@ fun ctx clock rt ->
    let attempts = ref 0 in
    let schedule =
      Schedule.both (Schedule.recurs 3) (Schedule.fibonacci (Duration.ms 5))
    in
    let attempt =
      Effect.sync (fun () ->
          incr attempts;
          !attempts)
      |> Effect.bind (fun n ->
             if n < 4 then Effect.fail (`Again n) else Effect.pure n)
    in
    let promise =
      B.fork_run ctx rt (Effect.retry ~schedule:schedule ~while_:(fun (`Again _) -> true) attempt)
    in
    wait_until (fun () -> !attempts = 1);
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    wait_until (fun () -> !attempts = 2);
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    wait_until (fun () -> !attempts = 3);
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 9);
    B.yield ();
    Alcotest.(check int) "third fibonacci delay not elapsed" 3 !attempts;
    B.adjust_clock clock (Duration.ms 1);
    check_exit_ok Alcotest.int "succeeded after fibonacci delays" 4
      (B.await promise)

  let test_effect_retry_windowed_schedule_uses_boundaries () =
    B.with_test_clock @@ fun ctx clock rt ->
    let attempts = ref 0 in
    let starts = ref [] in
    let schedule =
      Schedule.both (Schedule.recurs 2) (Schedule.windowed (Duration.ms 10))
    in
    let attempt =
      Effect.now
      |> Effect.bind (fun now_ms ->
             Effect.sync (fun () ->
                 starts := now_ms :: !starts;
                 incr attempts;
                 !attempts))
      |> Effect.bind (fun n ->
             if n < 3 then Effect.fail (`Again n) else Effect.pure n)
    in
    let promise =
      B.fork_run ctx rt (Effect.retry ~schedule:schedule ~while_:(fun (`Again _) -> true) attempt)
    in
    drive_clock_until_resolved clock promise;
    check_exit_ok Alcotest.int "retry result" 3 (B.await promise);
    Alcotest.(check (list int))
      "windowed retry starts on aligned boundaries" [ 0; 10; 20 ]
      (List.rev !starts)

  let test_effect_retry_during_bounds_elapsed () =
    B.with_test_clock @@ fun ctx clock rt ->
    let attempts = ref 0 in
    let starts = ref [] in
    let schedule =
      Schedule.both (Schedule.spaced (Duration.ms 10))
        (Schedule.during (Duration.ms 15))
    in
    let attempt =
      Effect.now
      |> Effect.bind (fun now_ms ->
             Effect.sync (fun () ->
                 starts := now_ms :: !starts;
                 incr attempts;
                 !attempts))
      |> Effect.bind (fun n -> Effect.fail (`Again n))
    in
    let promise =
      B.fork_run ctx rt (Effect.retry ~schedule:schedule ~while_:(fun (`Again _) -> true) attempt)
    in
    drive_clock_until_resolved clock promise;
    (match B.await promise with
    | Exit.Error (Cause.Fail (`Again 3)) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected final typed failure, got %a"
          (Cause.pp (fun fmt (`Again n) ->
               Format.fprintf fmt "Again %d" n))
          cause
    | Exit.Ok value -> Alcotest.failf "unexpected success %d" value);
    Alcotest.(check (list int))
      "retry stops once elapsed bound is exceeded" [ 0; 10; 20 ]
      (List.rev !starts)

  let test_effect_retry_timeout_interrupts_loop () =
    B.with_test_clock @@ fun ctx clock rt ->
    let attempts = ref 0 in
    let attempt : (unit, [ `Again | `Timed_out ]) Effect.t =
      Effect.sync (fun () -> incr attempts)
      |> Effect.bind (fun () -> Effect.fail `Again)
    in
    let eff =
      Effect.retry ~schedule:(Schedule.spaced (Duration.ms 10)) ~while_:(function `Again -> true | `Timed_out -> false) attempt
      |> Effect.timeout_as (Duration.ms 25) ~on_timeout:`Timed_out
    in
    let promise = B.fork_run ctx rt eff in
    wait_until (fun () -> !attempts = 1);
    Alcotest.(check int) "initial attempt" 1 !attempts;
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 10);
    B.yield ();
    Alcotest.(check int) "first retry" 2 !attempts;
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 10);
    B.yield ();
    Alcotest.(check int) "second retry" 3 !attempts;
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 5);
    match B.await promise with
    | Exit.Error (Cause.Fail `Timed_out) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected timeout, got %a"
          (Cause.pp (fun fmt -> function
            | `Again -> Format.pp_print_string fmt "Again"
            | `Timed_out -> Format.pp_print_string fmt "Timed_out"))
          cause
    | Exit.Ok _ -> Alcotest.fail "expected timeout"

  let test_effect_retry_jittered_schedule_uses_runtime_random () =
    B.with_seeded_test_clock ~seed:17 @@ fun ctx clock rt ->
    let attempts = ref 0 in
    let schedule =
      Schedule.spaced (Duration.ms 100)
      |> Schedule.jittered ~min:1.0 ~max:2.0
    in
    let attempt =
      Effect.named "attempt"
        (Effect.sync (fun () ->
             incr attempts;
             !attempts))
      |> Effect.bind (fun n ->
             if n < 2 then Effect.fail (`Again n) else Effect.pure n)
    in
    let promise =
      B.fork_run ctx rt (Effect.retry ~schedule:schedule ~while_:(fun (`Again _) -> true) attempt)
    in
    B.yield ();
    Alcotest.(check int) "first attempt" 1 !attempts;
    B.adjust_clock clock (Duration.ms 176);
    B.yield ();
    Alcotest.(check int) "still sleeping" 1 !attempts;
    B.adjust_clock clock (Duration.ms 1);
    check_exit_ok Alcotest.int "retry result" 2 (B.await promise)

  let test_effect_retry_releases_resources_each_failed_attempt () =
    B.with_runtime @@ fun _ctx rt ->
    let active = ref 0 in
    let max_active = ref 0 in
    let acquire =
      Effect.sync (fun () ->
          incr active;
          max_active := max !max_active !active)
    in
    let release () = Effect.sync (fun () -> decr active) in
    let attempts = ref 0 in
    let attempt =
      Effect.acquire_release ~acquire ~release
      |> Effect.bind (fun () ->
             incr attempts;
             if !attempts < 3 then Effect.fail (`Retry !attempts)
             else Effect.pure !attempts)
    in
    let eff =
      Effect.scoped
        (Effect.retry ~schedule:(Schedule.recurs 5) ~while_:(fun (`Retry _) -> true) attempt)
    in
    ignore (run_ok rt eff : int);
    Alcotest.(check int) "all released at end" 0 !active;
    Alcotest.(check int)
      "only one resource live at a time (retry should scope per-attempt)" 1
      !max_active

  let test_effect_retry_or_else_success () =
    B.with_runtime @@ fun _ctx rt ->
    let attempts = ref 0 in
    let fallback_called = ref false in
    let attempt =
      Effect.sync (fun () ->
          incr attempts;
          "ok")
    in
    let eff =
      Effect.retry_or_else ~schedule:(Schedule.recurs 3) ~while_:(fun (_ : string) -> true) ~or_else:(fun _ _ ->
          fallback_called := true;
          Effect.pure "fallback") attempt
    in
    Alcotest.(check string) "result" "ok" (run_ok rt eff);
    Alcotest.(check int) "one attempt" 1 !attempts;
    Alcotest.(check bool) "fallback skipped" false !fallback_called

  let test_effect_retry_or_else_eventual_success () =
    B.with_runtime @@ fun _ctx rt ->
    let attempts = ref 0 in
    let fallback_called = ref false in
    let attempt =
      Effect.sync (fun () ->
          incr attempts;
          !attempts)
      |> Effect.bind (fun n ->
             if n < 3 then Effect.fail (`Again n) else Effect.pure n)
    in
    let eff =
      Effect.retry_or_else ~schedule:(Schedule.recurs 5) ~while_:(fun (`Again _) -> true) ~or_else:(fun (`Again _) _ ->
          fallback_called := true;
          Effect.pure (-1)) attempt
    in
    Alcotest.(check int) "success" 3 (run_ok rt eff);
    Alcotest.(check int) "initial plus retries" 3 !attempts;
    Alcotest.(check bool) "fallback skipped" false !fallback_called

  let test_effect_retry_or_else_predicate_rejection_fallback () =
    B.with_runtime @@ fun _ctx rt ->
    let attempts = ref 0 in
    let fallback_seen = ref None in
    let fallback_output = ref None in
    let attempt =
      Effect.sync (fun () -> incr attempts)
      |> Effect.bind (fun () -> Effect.fail (`Reject !attempts))
    in
    let eff =
      Effect.retry_or_else ~schedule:(Schedule.recurs 5) ~while_:(fun (`Reject n) -> n < 2) ~or_else:(fun (`Reject n) output ->
          fallback_seen := Some n;
          fallback_output := output;
          Effect.pure ("fallback-" ^ string_of_int n)) attempt
    in
    Alcotest.(check string) "fallback result" "fallback-2" (run_ok rt eff);
    Alcotest.(check int) "initial plus accepted retry" 2 !attempts;
    Alcotest.(check (option int)) "fallback saw rejected error" (Some 2)
      !fallback_seen;
    Alcotest.(check (option int)) "fallback saw latest schedule output"
      (Some 0) !fallback_output

  let test_effect_retry_or_else_first_rejection_has_no_schedule_output () =
    B.with_runtime @@ fun _ctx rt ->
    let fallback_output = ref (Some (-1)) in
    let effect =
      Effect.fail (`Reject 1)
      |> Effect.retry_or_else ~schedule:(Schedule.recurs 5)
           ~while_:(fun (`Reject _) -> false)
           ~or_else:(fun (`Reject n) output ->
             fallback_output := output;
             Effect.pure ("fallback-" ^ string_of_int n))
    in
    Alcotest.(check string) "fallback result" "fallback-1" (run_ok rt effect);
    Alcotest.(check (option int)) "no schedule output" None !fallback_output

  let test_effect_retry_or_else_exhausted_fallback () =
    B.with_runtime @@ fun _ctx rt ->
    let attempts = ref 0 in
    let fallback_output = ref None in
    let attempt =
      Effect.sync (fun () -> incr attempts)
      |> Effect.bind (fun () -> Effect.fail (`Again !attempts))
    in
    let eff =
      Effect.retry_or_else ~schedule:(Schedule.recurs 2) ~while_:(fun (`Again _) -> true) ~or_else:(fun (`Again n) output ->
          fallback_output := output;
          Effect.pure ("exhausted-" ^ string_of_int n)) attempt
    in
    Alcotest.(check string) "fallback result" "exhausted-3" (run_ok rt eff);
    Alcotest.(check int) "initial plus two retries" 3 !attempts;
    Alcotest.(check (option int)) "fallback saw terminal schedule output"
      (Some 2) !fallback_output

  let test_effect_retry_or_else_fallback_failure_replaces_original () =
    B.with_runtime @@ fun _ctx rt ->
    let attempts = ref 0 in
    let attempt =
      Effect.sync (fun () -> incr attempts)
      |> Effect.bind (fun () -> Effect.fail `Again)
    in
    let eff =
      Effect.retry_or_else ~schedule:(Schedule.recurs 0) ~while_:(fun `Again -> true) ~or_else:(fun `Again _ -> Effect.fail `Fallback_failed) attempt
    in
    (match B.run rt eff with
    | Exit.Error (Cause.Fail `Fallback_failed) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected fallback failure, got %a"
          (Cause.pp (fun fmt `Fallback_failed ->
               Format.pp_print_string fmt "Fallback_failed"))
          cause
    | Exit.Ok _ -> Alcotest.fail "expected fallback failure");
    Alcotest.(check int) "initial only" 1 !attempts

  let test_effect_retry_or_else_composite_typed_failure () =
    B.with_runtime @@ fun _ctx rt ->
    let error_testable =
      Alcotest.testable
        (fun fmt -> function
          | `First -> Format.pp_print_string fmt "First"
          | `Second -> Format.pp_print_string fmt "Second")
        ( = )
    in
    let cause : [ `First | `Second ] Cause.t =
      Cause.Sequential [ Cause.Fail `First; Cause.Fail `Second ]
    in
    let fallback_seen = ref None in
    let fallback_output = ref None in
    let eff =
      effect_error_cause cause
      |> Effect.retry_or_else ~schedule:(Schedule.recurs 0) ~while_:(function `First | `Second -> true) ~or_else:(fun err output ->
             fallback_seen := Some err;
             fallback_output := output;
             Effect.pure "fallback")
    in
    Alcotest.(check string) "fallback result" "fallback" (run_ok rt eff);
    Alcotest.(check (option error_testable))
      "fallback saw first typed failure" (Some `First) !fallback_seen;
    Alcotest.(check (option int)) "fallback saw terminal output" (Some 0)
      !fallback_output

  let test_effect_retry_or_else_skips_uncatchable_causes () =
    B.with_runtime @@ fun _ctx rt ->
    let fallback_calls = ref 0 in
    let fallback (_ : string) _ =
      incr fallback_calls;
      Effect.pure "fallback"
    in
    let defect_attempts = ref 0 in
    let defect = Failure "retry_or_else defect" in
    let defect_attempt =
      Effect.sync (fun () ->
          incr defect_attempts;
          raise defect)
    in
    (match
       B.run rt
         (Effect.retry_or_else ~schedule:(Schedule.recurs 3) ~while_:(fun (_ : string) -> true) ~or_else:fallback defect_attempt)
     with
    | Exit.Error (Cause.Die die) when die.exn == defect -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected defect, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok value -> Alcotest.failf "unexpected fallback result %S" value);
    Alcotest.(check int) "defect not retried" 1 !defect_attempts;
    let interrupt_attempts = ref 0 in
    let interrupt_attempt =
      Effect.sync (fun () -> incr interrupt_attempts)
      |> Effect.bind (fun () -> runtime_interrupt_effect ())
    in
    (match
       B.run rt
         (Effect.retry_or_else ~schedule:(Schedule.recurs 3) ~while_:(fun (_ : string) -> true) ~or_else:fallback interrupt_attempt)
     with
    | Exit.Error (Cause.Interrupt None) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected interrupt, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok value -> Alcotest.failf "unexpected fallback result %S" value);
    Alcotest.(check int) "interrupt not retried" 1 !interrupt_attempts;
    let finalizer_attempts = ref 0 in
    let finalizer_attempt =
      Effect.sync (fun () -> incr finalizer_attempts)
      |> Effect.bind (fun () -> Effect.fail "body")
      |> Effect.finally (Effect.fail "cleanup")
    in
    (match
       B.run rt
         (Effect.retry_or_else ~schedule:(Schedule.recurs 3) ~while_:(fun (_ : string) -> true) ~or_else:fallback finalizer_attempt)
     with
    | Exit.Error (Cause.Finalizer (Cause.Finalizer.Fail "<typed failure>")) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected finalizer diagnostic, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok value -> Alcotest.failf "unexpected fallback result %S" value);
    Alcotest.(check int) "finalizer failure not retried" 1 !finalizer_attempts;
    Alcotest.(check int) "fallback skipped for uncatchable causes" 0
      !fallback_calls

  let test_effect_retry_or_else_uses_virtual_delays () =
    B.with_test_clock @@ fun ctx clock rt ->
    let attempts = ref 0 in
    let schedule =
      Schedule.both (Schedule.recurs 2) (Schedule.spaced (Duration.ms 5))
    in
    let attempt =
      Effect.sync (fun () -> incr attempts)
      |> Effect.bind (fun () -> Effect.fail (`Again !attempts))
    in
    let eff =
      Effect.retry_or_else ~schedule:schedule ~while_:(fun (`Again _) -> true) ~or_else:(fun (`Again n) _ ->
          Effect.pure ("fallback-" ^ string_of_int n)) attempt
    in
    let promise = B.fork_run ctx rt eff in
    wait_until (fun () -> !attempts = 1);
    Alcotest.(check int) "initial attempt" 1 !attempts;
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    wait_until (fun () -> !attempts = 2);
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    check_exit_ok Alcotest.string "fallback after delayed retries" "fallback-3"
      (B.await promise);
    Alcotest.(check int) "initial plus delayed retries" 3 !attempts

  let tests =
    [
      ( "Effect retry/repeat",
        [
          Alcotest.test_case "retry does nothing on initial success" `Quick
            test_effect_retry_does_nothing_on_initial_success;
          Alcotest.test_case "retry stops when predicate rejects" `Quick
            test_effect_retry_stops_when_predicate_rejects_typed_error;
          Alcotest.test_case "retry recurs attempts initial plus retries" `Quick
            test_effect_retry_recurs_attempts_initial_plus_retries;
          Alcotest.test_case "retry does not catch defects" `Quick
            test_effect_retry_does_not_catch_defects;
          Alcotest.test_case "retry does not retry cancellation" `Quick
            test_effect_retry_does_not_retry_cancellation;
          Alcotest.test_case "retry does not retry interrupt" `Quick
            test_effect_retry_does_not_retry_interrupt;
          Alcotest.test_case "repeat schedule" `Quick
            test_effect_repeat_schedule;
          Alcotest.test_case "repeat recurs zero runs body once" `Quick
            test_effect_repeat_recurs_zero_runs_body_once;
          Alcotest.test_case "repeat schedule uses virtual delays" `Quick
            test_effect_repeat_schedule_uses_virtual_delays;
          Alcotest.test_case "repeat fixed cadence differs from spaced" `Quick
            test_effect_repeat_fixed_cadence_differs_from_spaced;
          Alcotest.test_case "repeat fixed overrun has no pileup" `Quick
            test_effect_repeat_fixed_overrun_has_no_pileup;
          Alcotest.test_case "repeat timeout interrupts loop" `Quick
            test_effect_repeat_timeout_interrupts_loop;
          Alcotest.test_case "forever repeats until timeout" `Quick
            test_effect_forever_repeats_until_timeout;
          Alcotest.test_case "forever stops on typed failure" `Quick
            test_effect_forever_stops_on_typed_failure;
          Alcotest.test_case "forever stops on defect" `Quick
            test_effect_forever_stops_on_defect;
          Alcotest.test_case "forever stops on finalizer diagnostic" `Quick
            test_effect_forever_stops_on_finalizer_diagnostic;
          Alcotest.test_case "retry schedule until success" `Quick
            test_effect_retry_schedule_until_success;
          Alcotest.test_case "retry schedule uses virtual delays" `Quick
            test_effect_retry_schedule_uses_virtual_delays;
          Alcotest.test_case "schedule tap_input runs before inner step" `Quick
            test_schedule_tap_input_runs_before_inner_step;
          Alcotest.test_case "schedule tap_output runs on continue and done"
            `Quick test_schedule_tap_output_runs_on_continue_and_done;
          Alcotest.test_case "schedule tap failure stops retry without sleep"
            `Quick test_schedule_tap_failure_stops_retry_without_sleep;
          Alcotest.test_case "schedule tap failure stops repeat" `Quick
            test_schedule_tap_failure_stops_repeat;
          Alcotest.test_case "schedule tap callback exception is defect" `Quick
            test_schedule_tap_callback_exception_is_defect;
          Alcotest.test_case "schedule tap interruption is preserved" `Quick
            test_schedule_tap_interruption_is_preserved;
          Alcotest.test_case "retry uses fibonacci virtual delays" `Quick
            test_effect_retry_fibonacci_schedule_uses_virtual_delays;
          Alcotest.test_case "retry uses windowed boundaries" `Quick
            test_effect_retry_windowed_schedule_uses_boundaries;
          Alcotest.test_case "retry during schedule bounds elapsed" `Quick
            test_effect_retry_during_bounds_elapsed;
          Alcotest.test_case "retry timeout interrupts loop" `Quick
            test_effect_retry_timeout_interrupts_loop;
          Alcotest.test_case "retry jittered schedule uses runtime random" `Quick
            test_effect_retry_jittered_schedule_uses_runtime_random;
          Alcotest.test_case "retry releases resources each failed attempt"
            `Quick test_effect_retry_releases_resources_each_failed_attempt;
          Alcotest.test_case "retry_or_else success" `Quick
            test_effect_retry_or_else_success;
          Alcotest.test_case "retry_or_else eventual success" `Quick
            test_effect_retry_or_else_eventual_success;
          Alcotest.test_case "retry_or_else predicate rejection fallback" `Quick
            test_effect_retry_or_else_predicate_rejection_fallback;
          Alcotest.test_case "retry_or_else first rejection has no output"
            `Quick
            test_effect_retry_or_else_first_rejection_has_no_schedule_output;
          Alcotest.test_case "retry_or_else exhausted fallback" `Quick
            test_effect_retry_or_else_exhausted_fallback;
          Alcotest.test_case "retry_or_else fallback failure" `Quick
            test_effect_retry_or_else_fallback_failure_replaces_original;
          Alcotest.test_case "retry_or_else composite typed failure" `Quick
            test_effect_retry_or_else_composite_typed_failure;
          Alcotest.test_case "retry_or_else skips uncatchable causes" `Quick
            test_effect_retry_or_else_skips_uncatchable_causes;
          Alcotest.test_case "retry_or_else virtual delays" `Quick
            test_effect_retry_or_else_uses_virtual_delays;
        ] );
    ]
end
