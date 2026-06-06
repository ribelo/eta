open Eta
open Eta_test

let expect_failure name f =
  match f () with
  | () -> Alcotest.failf "%s: expected Alcotest failure" name
  | exception _ -> ()

let yield () = Eio.Fiber.yield ()

let wait_for_sleepers clock expected =
  let attempts = ref 0 in
  while Test_clock.sleeper_count clock < expected && !attempts < 20 do
    incr attempts;
    yield ()
  done

let fork_run sw rt eff =
  let promise, resolver = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.resolve resolver (Runtime.run rt eff));
  promise

let test_expect_ok () =
  Alcotest.(check int) "value" 1 (Expect.expect_ok (Exit.Ok 1));
  expect_failure "ok rejects error" (fun () ->
      ignore (Expect.expect_ok (Exit.Error (Cause.Fail "bad")) : int))

let test_expect_typed_failure () =
  let exit = Exit.Error (Cause.Fail "timeout") in
  Expect.expect_typed_failure exit (String.equal "timeout");
  Expect.expect_typed_failure_eq Alcotest.string exit "timeout";
  expect_failure "predicate mismatch" (fun () ->
      Expect.expect_typed_failure exit (String.equal "other"));
  expect_failure "eq mismatch" (fun () ->
      Expect.expect_typed_failure_eq Alcotest.string exit "other")

let test_expect_die () =
  let exn = Failure "boom" in
  let exit = Exit.Error (Cause.die exn) in
  Expect.expect_die exit (fun die -> die.exn == exn);
  expect_failure "die predicate mismatch" (fun () ->
      Expect.expect_die exit (fun _ -> false))

let test_expect_interrupt () =
  Expect.expect_interrupt (Exit.Error (Cause.Interrupt None));
  expect_failure "interrupt rejects ok" (fun () ->
      Expect.expect_interrupt (Exit.Ok ()))

let jittered_delays random =
  let schedule =
    Schedule.(jittered ~min:0.5 ~max:1.5 (spaced (Duration.ms 100)))
  in
  List.map
    (fun step ->
      Option.map Duration.to_ms (Schedule.next_delay ~random schedule ~step))
    [ 0; 1; 2; 3 ]

let runtime_retry_delays ~seed =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let random = Test_random.create ~seed in
  let delays = ref [] in
  let sleep duration =
    delays := duration :: !delays;
    Test_clock.sleep clock duration
  in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~sleep ~random ()
  in
  let attempts = ref 0 in
  let attempt =
    Effect.named "attempt" (Effect.sync (fun () ->
        incr attempts;
        !attempts))
    |> Effect.bind (fun attempt ->
           if attempt < 4 then Effect.fail "again" else Effect.pure attempt)
  in
  let schedule =
    Schedule.(jittered ~min:0.5 ~max:1.5 (spaced (Duration.ms 100)))
  in
  let promise =
    fork_run sw rt (Effect.retry schedule (String.equal "again") attempt)
  in
  for _ = 1 to 3 do
    wait_for_sleepers clock 1;
    Test_clock.adjust clock (Duration.seconds 1)
  done;
  Alcotest.(check int) "retry result" 4 (Expect.expect_ok (Eio.Promise.await promise));
  List.rev_map Duration.to_ms !delays

let test_random_same_seed_replays_runtime_jitter () =
  Alcotest.(check (list int))
    "same runtime jitter sequence"
    (runtime_retry_delays ~seed:123)
    (runtime_retry_delays ~seed:123)

let test_random_set_seed_resets_schedule_jitter () =
  let random = Test_random.create ~seed:123 in
  let first = jittered_delays random in
  ignore (jittered_delays random);
  Test_random.set_seed random 123;
  Alcotest.(check (list (option int))) "reset" first (jittered_delays random)

let test_clock_adjust_wakes_in_deadline_order () =
  with_test_clock @@ fun sw clock rt ->
  let observed = ref [] in
  let sleeper ms =
    Effect.delay (Duration.ms ms) (Effect.named "record" (Effect.sync (fun () ->
        observed := ms :: !observed)))
  in
  let promise =
    fork_run sw rt (Effect.all [ sleeper 30; sleeper 10; sleeper 20 ])
  in
  wait_for_sleepers clock 3;
  Test_clock.adjust clock (Duration.ms 30);
  ignore (Expect.expect_ok (Eio.Promise.await promise) : unit list);
  Alcotest.(check (list int)) "deadline order" [ 10; 20; 30 ]
    (List.rev !observed)

let test_clock_adjust_drains_cascading_sleeps () =
  with_test_clock @@ fun sw clock rt ->
  let observed = ref [] in
  let eff =
    Effect.delay (Duration.ms 10) (Effect.named "first" (Effect.sync (fun () ->
        observed := "first" :: !observed)))
    |> Effect.bind (fun () ->
           Effect.delay (Duration.ms 10) (Effect.named "second" (Effect.sync (fun () ->
               observed := "second" :: !observed))))
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 20);
  Expect.expect_ok (Eio.Promise.await promise);
  Alcotest.(check (list string)) "cascading sleeps" [ "first"; "second" ]
    (List.rev !observed)

let test_with_logger_captures_logs () =
  with_logger @@ fun _sw rt logger ->
  Expect.expect_ok (Runtime.run rt (Effect.log "hello"));
  match Logger.dump logger with
  | [ record ] -> Alcotest.(check string) "body" "hello" record.Logger.body
  | records -> Alcotest.failf "expected one log, got %d" (List.length records)

let test_with_tracer_captures_spans () =
  with_tracer @@ fun _sw rt tracer ->
  Expect.expect_ok
    (Runtime.run rt (Effect.named "span" (Effect.pure ())));
  match Tracer.dump tracer with
  | [ span ] -> Alcotest.(check string) "span" "span" span.Tracer.name
  | spans -> Alcotest.failf "expected one span, got %d" (List.length spans)

let test_with_logger_and_tracer_wires_both () =
  with_logger_and_tracer @@ fun _sw rt logger tracer ->
  Expect.expect_ok
    (Runtime.run rt (Effect.named "parent" (Effect.log "inside")));
  Alcotest.(check int) "logs" 1 (List.length (Logger.dump logger));
  Alcotest.(check int) "spans" 1 (List.length (Tracer.dump tracer))

let () =
  Alcotest.run "eta-test"
    [
      ( "Expect",
        [
          Alcotest.test_case "ok" `Quick test_expect_ok;
          Alcotest.test_case "typed failure" `Quick test_expect_typed_failure;
          Alcotest.test_case "die" `Quick test_expect_die;
          Alcotest.test_case "interrupt" `Quick test_expect_interrupt;
        ] );
      ( "Test_random",
        [
          Alcotest.test_case "same seed runtime jitter" `Quick
            test_random_same_seed_replays_runtime_jitter;
          Alcotest.test_case "set_seed resets schedule jitter" `Quick
            test_random_set_seed_resets_schedule_jitter;
        ] );
      ( "Test_clock",
        [
          Alcotest.test_case "adjust wakes in deadline order" `Quick
            test_clock_adjust_wakes_in_deadline_order;
          Alcotest.test_case "adjust drains cascading sleeps" `Quick
            test_clock_adjust_drains_cascading_sleeps;
        ] );
      ( "Observability",
        [
          Alcotest.test_case "with_logger" `Quick test_with_logger_captures_logs;
          Alcotest.test_case "with_tracer" `Quick test_with_tracer_captures_spans;
          Alcotest.test_case "with_logger_and_tracer" `Quick
            test_with_logger_and_tracer_wires_both;
        ] );
    ]
