let check label expected actual =
  if expected <> actual then
    failwith (Printf.sprintf "%s: expected %d, got %d" label expected actual)

let () =
  let module A = Duration_survival.Duration_keep in
  let module B = Duration_survival.Int_ms_branch in
  check "duration exponential" 40
    (A.Duration.to_ms
       (Option.get
          (A.Schedule.next_delay
             (A.Schedule.exponential ~factor:2.0 (A.Duration.ms 10))
             ~step:2)));
  check "int exponential" 40
    (Option.get
       (B.Schedule.next_delay (B.Schedule.exponential ~factor:2.0 10) ~step:2));
  check "duration both max" 2_000
    (A.Duration.to_ms
       (Option.get
          (A.Schedule.next_delay
             (A.Schedule.both (A.Schedule.spaced (A.Duration.seconds 1))
                (A.Schedule.spaced (A.Duration.seconds 2)))
             ~step:0)));
  check "int both max" 2_000
    (Option.get
       (B.Schedule.next_delay
          (B.Schedule.both (B.Schedule.spaced 1_000) (B.Schedule.spaced 2_000))
          ~step:0));
  print_endline "duration_survival runtime smoke passed"
