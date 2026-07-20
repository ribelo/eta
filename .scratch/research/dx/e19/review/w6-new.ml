(** W6 with DX-E19: the ordinary runtime stays unchanged; one combinator owns
    the assertion's fake-clock boundary. *)

let retry_three_times attempts =
  let open Eta.Syntax in
  let* () = Eta.Effect.sync (fun () -> incr attempts) in
  if !attempts <= 3 then Eta.Effect.fail `Retry else Eta.Effect.unit

let test_retry_delays sw runtime =
  let clock = Eta_test.Test_clock.create () in
  let attempts = ref 0 in
  let program =
    Eta.Effect.retry
      ~schedule:(Eta.Schedule.exponential (Eta.Duration.ms 10))
      ~while_:(fun `Retry -> true) (retry_three_times attempts)
    |> Eta.Effect.with_clock (Eta_test.Test_clock.as_capability clock)
  in
  let running = Eta_test.Async.fork_run sw runtime program in
  List.iter
    (fun ms ->
      while Eta_test.Test_clock.sleeper_count clock = 0 do
        Eta_test.Async.yield ()
      done;
      Eta_test.Test_clock.adjust clock (Eta.Duration.ms ms))
    [ 10; 20; 40 ];
  Eta_test.Expect.expect_ok (Eta_test.Async.await running);
  Alcotest.(check int) "slept exactly 10/20/40" 70
    (Eta_test.Test_clock.now_ms clock)
