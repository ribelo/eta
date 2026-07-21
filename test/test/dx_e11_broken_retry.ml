let broken_retry () =
  let attempts = ref 0 in
  let attempt =
    Eta.Effect.sync (fun () -> incr attempts)
    |> Eta.Effect.bind (fun () ->
           if !attempts <= 3 then Eta.Effect.fail "retry" else Eta.Effect.unit)
  in
  let schedule =
    Eta.Schedule.both (Eta.Schedule.recurs 3)
      (Eta.Schedule.linear ~initial:(Eta.Duration.ms 10)
         ~step:(Eta.Duration.ms 10))
  in
  let observed =
    Eta_test.Run.run
      (Eta.Effect.retry ~schedule ~while_:(String.equal "retry") attempt)
  in
  let expected_sleeps = List.map Eta.Duration.ms [ 10; 20; 40 ] in
  let expected =
    {
      observed with
      sleeps = expected_sleeps;
      events = List.map (fun duration -> Eta_test.Run.Sleep duration) expected_sleeps;
    }
  in
  Alcotest.check
    (Eta_test.Run.testable Alcotest.unit Alcotest.string)
    "retry backoff at Run.outcome.sleeps; expected exponential 10/20/40; inspect the schedule constructor"
    expected observed

let () =
  Alcotest.run "dx-e11-redteam"
    [
      ( "broken golden",
        [ Alcotest.test_case "retry slept 10/20/30" `Quick broken_retry ] );
    ]
