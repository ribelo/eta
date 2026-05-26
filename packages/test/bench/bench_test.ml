let repeat n f =
  for i = 1 to n do
    f i
  done

let clock_adjust n =
  let clock = Test.Test_clock.create () in
  repeat n (fun _ -> Test.Test_clock.adjust clock (Eta.Duration.ms 1))

let with_logger n =
  repeat n (fun _ ->
      Test.with_logger (fun _sw rt logger ->
          ignore (Eta.Runtime.run rt Eta.Effect.unit : (unit, _) Eta.Exit.t);
          ignore (Eta.Logger.dump logger)))

let expect_ok n =
  repeat n (fun i ->
      ignore (Test.Expect.expect_ok (Eta.Exit.Ok i)))

let workloads =
  let item name run =
    { Bench_lib.name = "test." ^ name; run; samples = None }
  in
  [
    item "clock.adjust.10k" (fun () -> clock_adjust 10_000);
    item "with_logger.1k" (fun () -> with_logger 1_000);
    item "expect_ok.100k" (fun () -> expect_ok 100_000);
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
