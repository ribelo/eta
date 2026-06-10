open Eta_test

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
      Eio.Promise.resolve resolver (Eta.Runtime.run rt eff));
  promise

let test_clock_adjust_wakes_in_deadline_order () =
  with_test_clock @@ fun sw clock rt ->
  let observed = ref [] in
  let sleeper ms =
    Eta.Effect.delay (Eta.Duration.ms ms) (Eta.Effect.named "record" (Eta.Effect.sync (fun () ->
        observed := ms :: !observed)))
  in
  let promise =
    fork_run sw rt (Eta.Effect.all [ sleeper 30; sleeper 10; sleeper 20 ])
  in
  wait_for_sleepers clock 3;
  Test_clock.adjust clock (Eta.Duration.ms 30);
  ignore (Expect.expect_ok (Eio.Promise.await promise) : unit list);
  Alcotest.(check (list int)) "deadline order" [ 10; 20; 30 ]
    (List.rev !observed)

let test_clock_adjust_drains_cascading_sleeps () =
  with_test_clock @@ fun sw clock rt ->
  let observed = ref [] in
  let eff =
    Eta.Effect.delay (Eta.Duration.ms 10) (Eta.Effect.named "first" (Eta.Effect.sync (fun () ->
        observed := "first" :: !observed)))
    |> Eta.Effect.bind (fun () ->
           Eta.Effect.delay (Eta.Duration.ms 10) (Eta.Effect.named "second" (Eta.Effect.sync (fun () ->
               observed := "second" :: !observed))))
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Eta.Duration.ms 20);
  Expect.expect_ok (Eio.Promise.await promise);
  Alcotest.(check (list string)) "cascading sleeps" [ "first"; "second" ]
    (List.rev !observed)

let test_with_logger_captures_logs () =
  with_logger @@ fun _sw rt logger ->
  Expect.expect_ok (Eta.Runtime.run rt (Eta.Effect.log "hello"));
  match Eta.Logger.dump logger with
  | [ record ] -> Alcotest.(check string) "body" "hello" record.Eta.Logger.body
  | records -> Alcotest.failf "expected one log, got %d" (List.length records)

let test_with_tracer_captures_spans () =
  with_tracer @@ fun _sw rt tracer ->
  Expect.expect_ok
    (Eta.Runtime.run rt (Eta.Effect.named "span" (Eta.Effect.pure ())));
  match Eta.Tracer.dump tracer with
  | [ span ] -> Alcotest.(check string) "span" "span" span.Eta.Tracer.name
  | spans -> Alcotest.failf "expected one span, got %d" (List.length spans)

let test_with_logger_and_tracer_wires_both () =
  with_logger_and_tracer @@ fun _sw rt logger tracer ->
  Expect.expect_ok
    (Eta.Runtime.run rt (Eta.Effect.named "parent" (Eta.Effect.log "inside")));
  Alcotest.(check int) "logs" 1 (List.length (Eta.Logger.dump logger));
  Alcotest.(check int) "spans" 1 (List.length (Eta.Tracer.dump tracer))

let () =
  Alcotest.run "eta-test"
    [
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
