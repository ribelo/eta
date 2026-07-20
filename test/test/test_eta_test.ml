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

let fresh_sequence_in_new_test_runtime () =
  with_test_clock @@ fun _sw _clock rt ->
  let open Eta.Syntax in
  let program =
    let* first = Eta.Effect.fresh () in
    let* second = Eta.Effect.fresh () in
    let+ third = Eta.Effect.fresh () in
    [ first; second; third ]
  in
  Expect.expect_ok (Eta.Runtime.run rt program)

let test_fresh_replays_across_test_runtimes () =
  let first = fresh_sequence_in_new_test_runtime () in
  let second = fresh_sequence_in_new_test_runtime () in
  Alcotest.(check (list int)) "first runtime sequence" [ 1; 2; 3 ] first;
  Alcotest.(check (list int)) "fresh test runtime replay" first second

let test_fresh_map_par_contention () =
  with_test_clock @@ fun _sw _clock rt ->
  let count = 10_000 in
  let started = Unix.gettimeofday () in
  let values =
    List.init count Fun.id
    |> Eta.Effect.map_par ~max_concurrent:64 (fun _ -> Eta.Effect.fresh ())
    |> Eta.Runtime.run rt |> Expect.expect_ok
  in
  let elapsed_ms = (Unix.gettimeofday () -. started) *. 1_000.0 in
  let unique = List.sort_uniq Int.compare values in
  Alcotest.(check int) "map_par pulls" count (List.length values);
  Alcotest.(check int) "map_par unique values" count (List.length unique);
  Format.printf "fresh map_par: n=%d max_concurrent=64 unique=%d elapsed_ms=%.3f@."
    count (List.length unique) elapsed_ms

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
      ( "Fresh",
        [
          Alcotest.test_case "replays across test runtimes" `Quick
            test_fresh_replays_across_test_runtimes;
          Alcotest.test_case "map_par contention" `Quick
            test_fresh_map_par_contention;
        ] );
    ]
