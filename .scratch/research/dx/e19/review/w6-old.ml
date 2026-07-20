(** W6 before DX-E19: the test owns a specially assembled runtime clock. *)

let retry_three_times attempts =
  let open Eta.Syntax in
  let* () = Eta.Effect.sync (fun () -> incr attempts) in
  if !attempts <= 3 then Eta.Effect.fail `Retry else Eta.Effect.unit

let test_retry_delays () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let runtime =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Eta_test.Test_clock.sleep clock)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
      ()
  in
  let attempts = ref 0 in
  let program =
    Eta.Effect.retry
      ~schedule:(Eta.Schedule.exponential (Eta.Duration.ms 10))
      ~while_:(fun `Retry -> true) (retry_three_times attempts)
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
