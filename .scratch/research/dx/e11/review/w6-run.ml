(** W6 with DX-E11: one call owns the deterministic runtime and returns every
    observation needed by the assertion. Compare the E19 packet's `w6-new.ml`,
    which still assembles a clock, forks the run, and drives three sleeps. *)

let retry_three_times attempts =
  let open Eta.Syntax in
  let* () = Eta.Effect.sync (fun () -> incr attempts) in
  if !attempts <= 3 then Eta.Effect.fail `Retry else Eta.Effect.unit

let test_retry_delays () =
  let attempts = ref 0 in
  let schedule =
    Eta.Schedule.both (Eta.Schedule.recurs 3)
      (Eta.Schedule.exponential ~factor:2.0 (Eta.Duration.ms 10))
  in
  let outcome =
    Eta_test.Run.run
      (Eta.Effect.retry ~schedule ~while_:(fun `Retry -> true)
         (retry_three_times attempts))
  in
  Eta_test.Expect.expect_ok outcome.exit;
  Eta_test.Run.expect_sleeps
    (List.map Eta.Duration.ms [ 10; 20; 40 ])
    outcome;
  Eta_test.Run.expect_no_pending_fibers outcome
