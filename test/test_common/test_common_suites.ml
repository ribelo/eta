open Eta
open Eta_test

let quick = `Quick

let expect_failure name f =
  match f () with
  | () -> Alcotest.failf "%s: expected Alcotest failure" name
  | exception _ -> ()

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
  let rec collect driver remaining acc =
    if remaining = 0 then List.rev acc
    else
      match Schedule.next ~now_ms:0 ~input:() driver with
      | None -> List.rev acc
      | Some (metadata, driver) ->
          collect driver (remaining - 1)
            (Some (Duration.to_ms metadata.delay) :: acc)
  in
  collect (Schedule.start ~random schedule) 4 []

let test_random_set_seed_resets_schedule_jitter () =
  let random = Test_random.create ~seed:123 in
  let first = jittered_delays random in
  ignore (jittered_delays random);
  Test_random.set_seed random 123;
  Alcotest.(check (list (option int))) "reset" first (jittered_delays random)

let base_tests =
  [
    ( "Expect",
      [
        Alcotest.test_case "ok" quick test_expect_ok;
        Alcotest.test_case "typed failure" quick test_expect_typed_failure;
        Alcotest.test_case "die" quick test_expect_die;
        Alcotest.test_case "interrupt" quick test_expect_interrupt;
      ] );
    ( "Test_random",
      [
        Alcotest.test_case "set_seed resets schedule jitter" quick
          test_random_set_seed_resets_schedule_jitter;
      ] );
  ]

module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  let wait_for_sleepers clock expected =
    let attempts = ref 0 in
    while B.sleeper_count clock < expected && !attempts < 20 do
      incr attempts;
      B.yield ()
    done;
    Alcotest.(check int) "sleepers" expected (B.sleeper_count clock)

  let runtime_retry_delays ~seed =
    B.with_seeded_logged_test_clock ~seed @@ fun ctx clock rt sleeps ->
    let attempts = ref 0 in
    let attempt =
      Effect.named "attempt"
        (Effect.sync (fun () ->
             incr attempts;
             !attempts))
      |> Effect.bind (fun attempt ->
             if attempt < 4 then Effect.fail "again" else Effect.pure attempt)
    in
    let schedule =
      Schedule.(jittered ~min:0.5 ~max:1.5 (spaced (Duration.ms 100)))
    in
    let promise =
      B.fork_run ctx rt (Effect.retry ~schedule:schedule ~while_:(String.equal "again") attempt)
    in
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.seconds 1);
    Alcotest.(check int) "retry result" 4 (Expect.expect_ok (B.await promise));
    List.rev_map Duration.to_ms !sleeps

  let test_random_same_seed_replays_runtime_jitter () =
    Alcotest.(check (list int))
      "same runtime jitter sequence"
      (runtime_retry_delays ~seed:123)
      (runtime_retry_delays ~seed:123)

  let test_clock_adjust_wakes_in_deadline_order () =
    B.with_test_clock @@ fun ctx clock rt ->
    let observed = ref [] in
    let sleeper ms =
      Effect.delay (Duration.ms ms)
        (Effect.named "record"
           (Effect.sync (fun () -> observed := ms :: !observed)))
    in
    let promise =
      B.fork_run ctx rt
        (Effect.all [ sleeper 30; sleeper 10; sleeper 20 ])
    in
    wait_for_sleepers clock 3;
    B.adjust_clock clock (Duration.ms 30);
    ignore (Expect.expect_ok (B.await promise) : unit list);
    Alcotest.(check (list int)) "deadline order" [ 10; 20; 30 ]
      (List.rev !observed)

  let test_clock_adjust_drains_cascading_sleeps () =
    B.with_test_clock @@ fun ctx clock rt ->
    let observed = ref [] in
    let eff =
      Effect.delay (Duration.ms 10)
        (Effect.named "first"
           (Effect.sync (fun () -> observed := "first" :: !observed)))
      |> Effect.bind (fun () ->
             Effect.delay (Duration.ms 10)
               (Effect.named "second"
                  (Effect.sync (fun () ->
                       observed := "second" :: !observed))))
    in
    let promise = B.fork_run ctx rt eff in
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 20);
    Expect.expect_ok (B.await promise);
    Alcotest.(check (list string)) "cascading sleeps" [ "first"; "second" ]
      (List.rev !observed)

  let test_logger_runtime_captures_logs () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    Expect.expect_ok (B.run rt (Effect.log "hello"));
    match Logger.dump logger with
    | [ record ] -> Alcotest.(check string) "body" "hello" record.Logger.body
    | records -> Alcotest.failf "expected one log, got %d" (List.length records)

  let test_traced_runtime_captures_spans () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    Expect.expect_ok (B.run rt (Effect.named "span" (Effect.pure ())));
    match Tracer.dump tracer with
    | [ span ] -> Alcotest.(check string) "span" "span" span.Tracer.name
    | spans -> Alcotest.failf "expected one span, got %d" (List.length spans)

  let test_observed_runtime_wires_logger_and_tracer () =
    B.with_observed_runtime @@ fun _ctx rt tracer logger _meter ->
    Expect.expect_ok
      (B.run rt (Effect.named "parent" (Effect.log "inside")));
    Alcotest.(check int) "logs" 1 (List.length (Logger.dump logger));
    Alcotest.(check int) "spans" 1 (List.length (Tracer.dump tracer))

  let tests =
    base_tests
    @ [
        ( "Test_clock",
          [
            Alcotest.test_case "adjust wakes in deadline order" quick
              test_clock_adjust_wakes_in_deadline_order;
            Alcotest.test_case "adjust drains cascading sleeps" quick
              test_clock_adjust_drains_cascading_sleeps;
          ] );
        ( "Test_random runtime",
          [
            Alcotest.test_case "same seed runtime jitter" quick
              test_random_same_seed_replays_runtime_jitter;
          ] );
        ( "Observability",
          [
            Alcotest.test_case "with logger runtime" quick
              test_logger_runtime_captures_logs;
            Alcotest.test_case "with traced runtime" quick
              test_traced_runtime_captures_spans;
            Alcotest.test_case "with observed runtime" quick
              test_observed_runtime_wires_logger_and_tracer;
          ] );
      ]
end
