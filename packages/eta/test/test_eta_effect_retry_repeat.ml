open Eta
open Eta_test
open Test_eta_support

let test_effect_retry_does_not_retry_interrupt () =
  with_runtime @@ fun rt ->
  let attempts = ref 0 in
  let attempt =
    Effect.named "interrupt" (Effect.sync (fun () ->
        incr attempts;
        raise (Eio.Cancel.Cancelled (Failure "cancel"))))
  in
  let eff = Effect.retry (Schedule.recurs 3) (fun (_ : string) -> true) attempt in
  (match Runtime.run rt eff with
  | Exit.Error (Cause.Interrupt None) -> ()
  | _ -> Alcotest.fail "expected Interrupt");
  Alcotest.(check int) "not retried" 1 !attempts

let test_effect_retry_preserves_structured_exception_causes () =
  with_runtime @@ fun rt ->
  let left = Failure "retry-left" in
  let right = Failure "retry-right" in
  let backtrace = Printexc.get_callstack 4 in
  let attempt =
    Effect.sync (fun () ->
        raise (Eio.Exn.Multiple [ (left, backtrace); (right, backtrace) ]))
  in
  match
    Runtime.run rt
      (Effect.retry (Schedule.recurs 0) (fun (_ : string) -> false) attempt)
  with
  | Exit.Error (Cause.Concurrent [ Cause.Die left_die; Cause.Die right_die ]) ->
      Alcotest.(check bool) "left exception" true (left_die.exn == left);
      Alcotest.(check bool) "right exception" true (right_die.exn == right)
  | Exit.Error cause ->
      Alcotest.failf "expected concurrent retry cause, got %a"
        (Cause.pp Format.pp_print_string)
        cause
  | Exit.Ok _ -> Alcotest.fail "expected retry failure"


let test_effect_repeat_schedule () =
  with_runtime @@ fun rt ->
  let ticks = ref 0 in
  let tick = Effect.named "tick" (Effect.sync (fun () -> incr ticks)) in
  run_ok rt (Effect.repeat (Schedule.recurs 3) tick);
  Alcotest.(check int) "initial run plus three repeats" 4 !ticks

let test_effect_repeat_schedule_uses_virtual_delays () =
  with_test_clock @@ fun sw clock rt ->
  let ticks = ref 0 in
  let schedule =
    Schedule.both (Schedule.recurs 3) (Schedule.spaced (Duration.ms 5))
  in
  let promise =
    fork_run sw rt (Effect.named "tick" (Effect.sync (fun () -> incr ticks)) |> Effect.repeat schedule)
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
    Effect.named "attempt" (Effect.sync (fun () ->
        incr attempts;
        !attempts))
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
    Effect.named "attempt" (Effect.sync (fun () ->
        incr attempts;
        !attempts))
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

let test_effect_retry_jittered_schedule_uses_runtime_random () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Test_clock.sleep clock)
      ~random:(Capabilities.random_of_seed 17)
      ()
  in
  let attempts = ref 0 in
  let schedule =
    Schedule.spaced (Duration.ms 100)
    |> Schedule.jittered ~min:1.0 ~max:2.0
  in
  let attempt =
    Effect.named "attempt" (Effect.sync (fun () ->
        incr attempts;
        !attempts))
    |> Effect.bind (fun n ->
           if n < 2 then Effect.fail (`Again n) else Effect.pure n)
  in
  let promise =
    fork_run sw rt (Effect.retry schedule (fun (`Again _) -> true) attempt)
  in
  yield ();
  Alcotest.(check int) "first attempt" 1 !attempts;
  Test_clock.adjust clock (Duration.ms 138);
  yield ();
  Alcotest.(check int) "still sleeping" 1 !attempts;
  Test_clock.adjust clock (Duration.ms 1);
  check_exit_ok Alcotest.int "retry result" 2 (Eio.Promise.await promise)



