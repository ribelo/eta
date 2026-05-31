open Eta
open Eta_test
open Test_eta_support

let test_duration_constructors () =
  Alcotest.(check dur) "seconds" (Duration.ms 1_000) (Duration.seconds 1);
  Alcotest.(check dur) "minutes" (Duration.seconds 60) (Duration.minutes 1);
  Alcotest.(check dur) "hours" (Duration.minutes 60) (Duration.hours 1);
  Alcotest.(check dur) "days" (Duration.hours 24) (Duration.days 1);
  Alcotest.(check dur) "weeks" (Duration.days 7) (Duration.weeks 1)

let test_duration_ordering () =
  Alcotest.(check int) "lt" (-1)
    (Duration.compare (Duration.ms 1) (Duration.ms 2));
  Alcotest.(check int) "eq" 0
    (Duration.compare (Duration.ms 2) (Duration.ms 2));
  Alcotest.(check int) "gt" 1
    (Duration.compare (Duration.ms 2) (Duration.ms 1));
  Alcotest.(check bool) "between" true
    (Duration.between ~min:(Duration.minutes 59) ~max:(Duration.minutes 61)
       (Duration.hours 1));
  Alcotest.(check bool) "below range" false
    (Duration.between ~min:(Duration.minutes 59) ~max:(Duration.minutes 61)
       (Duration.minutes 58));
  Alcotest.(check bool) "above range" false
    (Duration.between ~min:(Duration.minutes 59) ~max:(Duration.minutes 61)
       (Duration.minutes 62))

let test_duration_algebra () =
  Alcotest.(check dur) "sum" (Duration.minutes 1)
    (Duration.add (Duration.seconds 30) (Duration.seconds 30));
  Alcotest.(check dur) "subtract clamps at zero" Duration.zero
    (Duration.subtract (Duration.seconds 30) (Duration.seconds 40));
  Alcotest.(check dur) "times" (Duration.minutes 1)
    (Duration.times (Duration.seconds 1) 60);
  Alcotest.(check some_dur) "divide" (Some (Duration.seconds 30))
    (Duration.divide (Duration.minutes 1) 2);
  Alcotest.(check some_dur) "divide by zero" None
    (Duration.divide (Duration.minutes 1) 0)

let test_duration_overflow () =
  let overflowing_hours = (max_int / 3_600_000) + 1 in
  Alcotest.check_raises "large hours overflow" (Invalid_argument "Duration.hours")
    (fun () -> ignore (Duration.hours overflowing_hours));
  Alcotest.check_raises "add overflow" (Invalid_argument "Duration.add")
    (fun () -> ignore (Duration.add (Duration.ms max_int) (Duration.ms 1)));
  Alcotest.check_raises "times overflow" (Invalid_argument "Duration.times")
    (fun () -> ignore (Duration.times (Duration.ms max_int) 2))

let test_duration_min_max_clamp () =
  Alcotest.(check dur) "max" (Duration.ms 2)
    (Duration.max (Duration.ms 1) (Duration.ms 2));
  Alcotest.(check dur) "min" (Duration.ms 1)
    (Duration.min (Duration.ms 1) (Duration.ms 2));
  Alcotest.(check dur) "clamp lower" (Duration.ms 2)
    (Duration.clamp ~min:(Duration.ms 2) ~max:(Duration.ms 3)
       (Duration.ms 1));
  Alcotest.(check dur) "clamp upper" (Duration.ms 3)
    (Duration.clamp ~min:(Duration.ms 2) ~max:(Duration.ms 3)
       (Duration.ms 4));
  Alcotest.(check dur) "clamp inside" (Duration.minutes 90)
    (Duration.clamp ~min:(Duration.minutes 60) ~max:(Duration.minutes 120)
       (Duration.minutes 90))

let test_duration_zero_detection_and_conversion () =
  Alcotest.(check bool) "zero is zero" true (Duration.is_zero Duration.zero);
  Alcotest.(check bool) "positive is not zero" false
    (Duration.is_zero (Duration.ms 1));
  Alcotest.(check int) "seconds to ms" 2_000
    (Duration.to_ms (Duration.seconds 2));
  Alcotest.(check (float 0.0)) "ms to seconds float" 1.5
    (Duration.to_seconds_float (Duration.ms 1_500))

let test_recurs () =
  let s = Schedule.recurs 3 in
  Alcotest.(check some_dur) "0" (Some Duration.zero)
    (Schedule.next_delay s ~step:0);
  Alcotest.(check some_dur) "exhausted" None
    (Schedule.next_delay s ~step:3)

let test_recurs_driver_yields_exactly_n_delays () =
  let rec collect driver acc =
    match Schedule.next driver with
    | None -> List.rev acc
    | Some (delay, next) -> collect next (delay :: acc)
  in
  Alcotest.(check (list dur))
    "three recurrences"
    [ Duration.zero; Duration.zero; Duration.zero ]
    (collect (Schedule.start (Schedule.recurs 3)) [])

let test_exponential () =
  let s = Schedule.exponential ~factor:2.0 (dur_ms 10) in
  Alcotest.(check some_dur) "step 0" (Some (dur_ms 10))
    (Schedule.next_delay s ~step:0);
  Alcotest.(check some_dur) "step 2 = 40ms" (Some (dur_ms 40))
    (Schedule.next_delay s ~step:2)

let test_spaced_fixed_linear () =
  Alcotest.(check some_dur) "spaced" (Some (Duration.seconds 1))
    (Schedule.next_delay (Schedule.spaced (Duration.seconds 1)) ~step:4);
  Alcotest.(check some_dur) "fixed" (Some (Duration.seconds 1))
    (Schedule.next_delay (Schedule.fixed (Duration.seconds 1)) ~step:4);
  Alcotest.(check some_dur) "linear step 3" (Some (Duration.seconds 7))
    (Schedule.next_delay
       (Schedule.linear ~initial:(Duration.seconds 1)
          ~step:(Duration.seconds 2))
       ~step:3)

let test_schedule_composition () =
  Alcotest.(check some_dur) "both takes max" (Some (Duration.seconds 2))
    (Schedule.next_delay
       (Schedule.both (Schedule.spaced (Duration.seconds 1))
          (Schedule.spaced (Duration.seconds 2)))
       ~step:0);
  Alcotest.(check some_dur) "either takes min" (Some (Duration.seconds 1))
    (Schedule.next_delay
       (Schedule.either (Schedule.spaced (Duration.seconds 1))
          (Schedule.spaced (Duration.seconds 2)))
       ~step:0);
  Alcotest.(check some_dur) "and_then falls through" (Some (Duration.seconds 1))
    (Schedule.next_delay
       (Schedule.and_then (Schedule.recurs 1)
          (Schedule.spaced (Duration.seconds 1)))
       ~step:1)

let test_schedule_composition_termination_with_driver () =
  let collect schedule =
    let rec loop driver acc =
      match Schedule.next driver with
      | None -> List.rev acc
      | Some (delay, next) -> loop next (delay :: acc)
    in
    loop (Schedule.start schedule) []
  in
  Alcotest.(check (list dur)) "both terminates with shorter side"
    [ Duration.seconds 2; Duration.seconds 2 ]
    (collect
       (Schedule.both
          (Schedule.both (Schedule.recurs 2) (Schedule.spaced (Duration.seconds 1)))
          (Schedule.spaced (Duration.seconds 2))));
  Alcotest.(check (list dur)) "either terminates with longer side"
    [ Duration.seconds 1; Duration.seconds 1; Duration.seconds 2 ]
    (collect
       (Schedule.either
          (Schedule.both (Schedule.recurs 2) (Schedule.spaced (Duration.seconds 1)))
          (Schedule.both (Schedule.recurs 3) (Schedule.spaced (Duration.seconds 2)))));
  Alcotest.(check (list dur)) "and_then runs second phase after first"
    [ Duration.zero; Duration.seconds 1; Duration.seconds 1 ]
    (collect
       (Schedule.and_then (Schedule.recurs 1)
          (Schedule.both (Schedule.recurs 2) (Schedule.spaced (Duration.seconds 1)))))

let test_schedule_and_then_offsets_second_phase () =
  let exponential =
    Schedule.and_then (Schedule.recurs 5)
      (Schedule.exponential ~factor:2.0 (Duration.seconds 1))
  in
  List.iter
    (fun step ->
      Alcotest.(check some_dur)
        ("exponential warmup " ^ string_of_int step)
        (Some Duration.zero)
        (Schedule.next_delay exponential ~step))
    [ 0; 1; 2; 3; 4 ];
  Alcotest.(check some_dur) "exponential phase step 0"
    (Some (Duration.seconds 1))
    (Schedule.next_delay exponential ~step:5);
  Alcotest.(check some_dur) "exponential phase step 1"
    (Some (Duration.seconds 2))
    (Schedule.next_delay exponential ~step:6);
  Alcotest.(check some_dur) "exponential phase step 2"
    (Some (Duration.seconds 4))
    (Schedule.next_delay exponential ~step:7);
  let linear =
    Schedule.and_then (Schedule.recurs 3)
      (Schedule.linear ~initial:(Duration.ms 100) ~step:(Duration.ms 50))
  in
  Alcotest.(check some_dur) "linear phase step 0" (Some (Duration.ms 100))
    (Schedule.next_delay linear ~step:3);
  Alcotest.(check some_dur) "linear phase step 1" (Some (Duration.ms 150))
    (Schedule.next_delay linear ~step:4);
  let jittered =
    Schedule.and_then (Schedule.recurs 2)
      (Schedule.exponential ~factor:2.0 (Duration.ms 100))
    |> Schedule.jittered ~min:1.0 ~max:1.0
  in
  Alcotest.(check some_dur) "jittered wraps second phase step 0"
    (Some (Duration.ms 100))
    (Schedule.next_delay jittered ~step:2)

let test_schedule_jittered_uses_random_capability () =
  let random = Capabilities.random_of_seed 17 in
  let schedule =
    Schedule.spaced (Duration.ms 100)
    |> Schedule.jittered ~min:1.0 ~max:2.0
  in
  Alcotest.(check some_dur) "jittered factor from capability"
    (Some (Duration.ms 177))
    (Schedule.next_delay ~random schedule ~step:0);
  let random = Capabilities.random_of_seed 7 in
  Alcotest.(check int) "inclusive range" 20
    (Random.int_in_range random ~min:10 ~max:20);
  let random = Capabilities.random_of_seed 7 in
  Alcotest.(check (float 0.0000001))
    "float range" 2.945698134713836
    (Random.float_in_range random ~min:1.0 ~max:3.0);
  let random = Capabilities.random_of_seed 7 in
  Alcotest.(check bool) "bool" true (Random.bool random);
  let random = Capabilities.random_of_seed 7 in
  Alcotest.(check (list int)) "shuffle" [ 1; 2; 3; 4 ]
    (Random.shuffle random [ 1; 2; 3; 4 ]);
  let random = Capabilities.random_of_seed 7 in
  Alcotest.(check (option string))
    "weighted choice" (Some "c")
    (Random.weighted_choice random [ ("a", 1.0); ("b", 2.0); ("c", 1.0) ]);
  let random = Capabilities.random_of_seed 7 in
  Alcotest.(check (option int)) "sample" (Some 40)
    (Random.sample random [ 10; 20; 30; 40 ]);
  Alcotest.(check (option int)) "empty" None (Random.sample random [])

let test_schedule_jittered_stays_inside_multiplier_bounds () =
  let schedule =
    Schedule.spaced (Duration.ms 100)
    |> Schedule.jittered ~min:0.5 ~max:1.5
  in
  let driver = ref (Schedule.start ~random:(Capabilities.random_of_seed 23) schedule) in
  for step = 0 to 99 do
    match Schedule.next !driver with
    | None -> Alcotest.fail "jittered spaced schedule terminated"
    | Some (delay, next) ->
        driver := next;
        Alcotest.(check bool)
          ("step " ^ string_of_int step ^ " inside lower bound")
          true
          (Duration.compare delay (Duration.ms 50) >= 0);
        Alcotest.(check bool)
          ("step " ^ string_of_int step ^ " inside upper bound")
          true
          (Duration.compare delay (Duration.ms 150) <= 0)
  done

let test_random_float_distribution_and_determinism () =
  let first = Capabilities.random_of_seed 12345 in
  let second = Capabilities.random_of_seed 12345 in
  for _ = 1 to 100 do
    Alcotest.(check (float 0.0)) "same seed sequence"
      (Capabilities.random_float first 1.0)
      (Capabilities.random_float second 1.0)
  done;
  let random = Capabilities.random_of_seed 12345 in
  let bins = Array.make 10 0 in
  for _ = 1 to 100_000 do
    let sample = Capabilities.random_float random 1.0 in
    let bin = min 9 (int_of_float (sample *. 10.0)) in
    bins.(bin) <- bins.(bin) + 1
  done;
  Array.iteri
    (fun bin count ->
      Alcotest.(check bool)
        (Printf.sprintf "bin %d roughly uniform" bin)
        true
        (count >= 9_000 && count <= 11_000))
    bins
