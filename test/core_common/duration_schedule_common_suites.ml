open Eta

let dur_ms = Duration.ms
let some_dur = Alcotest.option (Alcotest.testable Duration.pp Duration.equal)
let dur = Alcotest.testable Duration.pp Duration.equal

let next_delay ?random ?(now_ms = 0) ?(input = ()) schedule ~step =
  let rec advance driver remaining =
    match Schedule.next ~now_ms ~input driver with
    | None -> None
    | Some (metadata, driver) ->
        if remaining <= 0 then Some metadata.delay
        else advance driver (remaining - 1)
  in
  advance (Schedule.start ?random schedule) step

let next_continue ?(now_ms = 0) ?(input = ()) driver =
  match Schedule.next ~now_ms ~input driver with
  | None -> Alcotest.fail "schedule ended"
  | Some (metadata, driver) -> (metadata, driver)

let next_continue_with_input ?(now_ms = 0) ~input driver =
  match Schedule.next ~now_ms ~input driver with
  | None -> Alcotest.fail "schedule ended"
  | Some (metadata, driver) -> (metadata, driver)

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

let test_duration_scale_identity_at_max () =
  Alcotest.(check int)
    "scale by 1.0 must be the identity"
    max_int
    (Duration.to_ms (Duration.scale (Duration.ms max_int) 1.0))

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

let test_duration_humanize () =
  Alcotest.(check string) "zero" "0" (Duration.humanize Duration.zero);
  Alcotest.(check string) "millis" "42ms" (Duration.humanize (Duration.ms 42));
  Alcotest.(check string) "second and millis" "1s 1ms"
    (Duration.humanize (Duration.ms 1_001));
  Alcotest.(check string) "compound" "2d 3h 4m 5s 6ms"
    (Duration.humanize
       Duration.(
         days 2 + hours 3 + minutes 4 + seconds 5 + ms 6))

let test_recurs () =
  let s = Schedule.recurs 3 in
  Alcotest.(check some_dur) "0" (Some Duration.zero)
    (next_delay s ~step:0);
  Alcotest.(check some_dur) "exhausted" None
    (next_delay s ~step:3)

let test_recurs_driver_yields_exactly_n_delays () =
  let rec collect driver acc =
    match Schedule.next ~now_ms:0 ~input:() driver with
    | None -> List.rev acc
    | Some (metadata, next) -> collect next (metadata.delay :: acc)
  in
  Alcotest.(check (list dur))
    "three recurrences"
    [ Duration.zero; Duration.zero; Duration.zero ]
    (collect (Schedule.start (Schedule.recurs 3)) [])

let test_exponential () =
  let s = Schedule.exponential ~factor:2.0 (dur_ms 10) in
  Alcotest.(check some_dur) "step 0" (Some (dur_ms 10))
    (next_delay s ~step:0);
  Alcotest.(check some_dur) "step 2 = 40ms" (Some (dur_ms 40))
    (next_delay s ~step:2)

let test_exponential_saturates_on_overflow () =
  let s = Schedule.exponential ~factor:2.0 (Duration.ms max_int) in
  Alcotest.(check some_dur)
    "large exponent saturates"
    (Some (Duration.ms max_int))
    (next_delay s ~step:1024)

let collect_with_now schedule nows =
  let rec loop driver acc = function
    | [] -> List.rev acc
    | now_ms :: rest -> (
        match Schedule.next ~now_ms ~input:() driver with
        | None -> Alcotest.fail "schedule ended"
        | Some (metadata, next) -> loop next (metadata.delay :: acc) rest)
  in
  loop (Schedule.start schedule) [] nows

let test_fixed_uses_cadence_with_now_metadata () =
  let schedule = Schedule.fixed (Duration.ms 5_000) in
  Alcotest.(check (list dur))
    "fixed cadence delays"
    (List.map Duration.ms [ 5_000; 3_500; 0; 3_000 ])
    (collect_with_now schedule [ 0; 6_500; 16_000; 17_000 ])

let test_windowed () =
  let schedule = Schedule.windowed (Duration.ms 10) in
  Alcotest.(check (list dur))
    "window boundary delays"
    (List.map Duration.ms [ 10; 7; 10; 3 ])
    (collect_with_now schedule [ 0; 13; 20; 27 ]);
  let zero = Schedule.windowed Duration.zero in
  List.iter
    (fun step ->
      Alcotest.(check some_dur)
        ("zero step " ^ string_of_int step)
        (Some Duration.zero)
        (next_delay zero ~step))
    [ 0; 1; 2; 3 ]

let test_schedule_outputs_and_done_decision () =
  let driver = Schedule.start (Schedule.recurs 3) in
  let metadata, driver = next_continue driver in
  Alcotest.(check int) "first output" 0 metadata.output;
  Alcotest.(check int) "first attempt" 1 metadata.attempt;
  let metadata, driver = next_continue driver in
  Alcotest.(check int) "second output" 1 metadata.output;
  let metadata, driver = next_continue driver in
  Alcotest.(check int) "third output" 2 metadata.output;
  match Schedule.step ~now_ms:0 ~input:() driver with
  | Schedule.Done metadata, _ ->
      Alcotest.(check int) "done output" 3 metadata.output;
      Alcotest.(check dur) "done delay" Duration.zero metadata.delay
  | Schedule.Continue _, _ -> Alcotest.fail "expected done decision"

let test_schedule_elapsed_accumulates_from_first_step () =
  let driver = Schedule.start Schedule.elapsed in
  let metadata, driver = next_continue ~now_ms:100 driver in
  Alcotest.(check dur) "initial elapsed" Duration.zero metadata.output;
  Alcotest.(check int) "start" 100 metadata.start_ms;
  let metadata, driver = next_continue ~now_ms:125 driver in
  Alcotest.(check dur) "second elapsed" (Duration.ms 25) metadata.output;
  Alcotest.(check dur)
    "elapsed since previous" (Duration.ms 25)
    metadata.elapsed_since_previous;
  let metadata, _ = next_continue ~now_ms:180 driver in
  Alcotest.(check dur) "third elapsed" (Duration.ms 80) metadata.output;
  Alcotest.(check dur)
    "third since previous" (Duration.ms 55)
    metadata.elapsed_since_previous

let test_schedule_during_stops_after_bound () =
  let driver = Schedule.start (Schedule.during (Duration.ms 50)) in
  let metadata, driver = next_continue ~now_ms:0 driver in
  Alcotest.(check dur) "initial output" Duration.zero metadata.output;
  let metadata, driver = next_continue ~now_ms:50 driver in
  Alcotest.(check dur) "boundary still continues" (Duration.ms 50) metadata.output;
  match Schedule.step ~now_ms:51 ~input:() driver with
  | Schedule.Done metadata, _ ->
      Alcotest.(check dur) "done output" (Duration.ms 51) metadata.output
  | Schedule.Continue _, _ -> Alcotest.fail "expected during to stop"

let test_schedule_output_predicates_and_recur_until () =
  let driver =
    Schedule.forever |> Schedule.while_output (fun output -> output < 3)
    |> Schedule.start
  in
  let metadata, driver = next_continue driver in
  Alcotest.(check int) "while output 0" 0 metadata.output;
  let metadata, driver = next_continue driver in
  Alcotest.(check int) "while output 1" 1 metadata.output;
  let metadata, driver = next_continue driver in
  Alcotest.(check int) "while output 2" 2 metadata.output;
  (match Schedule.step ~now_ms:0 ~input:() driver with
  | Schedule.Done metadata, _ ->
      Alcotest.(check int) "while done output" 3 metadata.output
  | Schedule.Continue _, _ -> Alcotest.fail "expected while_output to stop");
  let driver =
    Schedule.recur_until (String.equal "stop")
    |> Schedule.start
  in
  let metadata, driver = next_continue_with_input ~input:"a" driver in
  Alcotest.(check string) "first input output" "a" metadata.output;
  let metadata, driver = next_continue_with_input ~input:"b" driver in
  Alcotest.(check string) "second input output" "b" metadata.output;
  match Schedule.step ~now_ms:0 ~input:"stop" driver with
  | Schedule.Done metadata, _ ->
      Alcotest.(check string) "stop output" "stop" metadata.output
  | Schedule.Continue _, _ -> Alcotest.fail "expected recur_until to stop"

let test_schedule_modify_delay () =
  let schedule =
    Schedule.spaced (Duration.ms 10)
    |> Schedule.modify_delay (fun output delay ->
           Duration.ms (Duration.to_ms delay + output))
  in
  let driver = Schedule.start schedule in
  let metadata, driver = next_continue driver in
  Alcotest.(check dur) "first modified delay" (Duration.ms 10) metadata.delay;
  let metadata, _ = next_continue driver in
  Alcotest.(check dur) "second modified delay" (Duration.ms 11) metadata.delay

let test_schedule_taps_input_and_output () =
  let inputs = ref [] in
  let outputs = ref [] in
  let schedule =
    Schedule.recurs 2
    |> Schedule.tap_input (fun input -> inputs := input :: !inputs)
    |> Schedule.tap_output (fun output -> outputs := output :: !outputs)
  in
  let driver = Schedule.start schedule in
  let _, driver = next_continue_with_input ~input:"a" driver in
  let _, driver = next_continue_with_input ~input:"b" driver in
  (match Schedule.step ~now_ms:0 ~input:"c" driver with
  | Schedule.Done _, _ -> ()
  | Schedule.Continue _, _ -> Alcotest.fail "expected tapped schedule to stop");
  Alcotest.(check (list string)) "inputs" [ "a"; "b"; "c" ]
    (List.rev !inputs);
  Alcotest.(check (list int)) "outputs" [ 0; 1; 2 ] (List.rev !outputs)

let test_fibonacci () =
  let schedule = Schedule.fibonacci (dur_ms 10) in
  let rec collect driver remaining acc =
    if remaining = 0 then List.rev acc
    else
      match Schedule.next ~now_ms:0 ~input:() driver with
      | None -> Alcotest.fail "fibonacci schedule ended"
      | Some (metadata, next) ->
          collect next (remaining - 1) (metadata.delay :: acc)
  in
  Alcotest.(check (list dur))
    "first fibonacci delays"
    (List.map dur_ms [ 10; 10; 20; 30; 50; 80; 130; 210 ])
    (collect (Schedule.start schedule) 8 [])

let test_fibonacci_composes_with_recurs_driver () =
  let schedule =
    Schedule.both (Schedule.recurs 6) (Schedule.fibonacci (Duration.ms 5))
  in
  let rec collect driver acc =
    match Schedule.next ~now_ms:0 ~input:() driver with
    | None -> List.rev acc
    | Some (metadata, next) -> collect next (metadata.delay :: acc)
  in
  Alcotest.(check (list dur))
    "recurs limits fibonacci driver"
    (List.map Duration.ms [ 5; 5; 10; 15; 25; 40 ])
    (collect (Schedule.start schedule) [])

let test_schedule_composition_outputs () =
  let driver =
    Schedule.both (Schedule.recurs 2) (Schedule.fibonacci (Duration.ms 5))
    |> Schedule.start
  in
  let metadata, driver = next_continue driver in
  Alcotest.(check (pair int dur)) "first output" (0, Duration.ms 5)
    metadata.output;
  let metadata, driver = next_continue driver in
  Alcotest.(check (pair int dur)) "second output" (1, Duration.ms 5)
    metadata.output;
  match Schedule.step ~now_ms:0 ~input:() driver with
  | Schedule.Done metadata, _ ->
      Alcotest.(check (pair int dur)) "done output" (2, Duration.ms 10)
        metadata.output
  | Schedule.Continue _, _ -> Alcotest.fail "expected composed schedule to stop"

let test_fibonacci_edges () =
  let zero = Schedule.fibonacci Duration.zero in
  List.iter
    (fun step ->
      Alcotest.(check some_dur)
        ("zero step " ^ string_of_int step)
        (Some Duration.zero)
        (next_delay zero ~step))
    [ 0; 1; 2; 3 ];
  let base = Duration.ms ((max_int / 2) + 1) in
  let driver = Schedule.start (Schedule.fibonacci base) in
  let driver =
    match Schedule.next ~now_ms:0 ~input:() driver with
    | Some (metadata, next) ->
        Alcotest.(check dur) "first delay" base metadata.delay;
        next
    | None -> Alcotest.fail "fibonacci schedule ended before first delay"
  in
  let driver =
    match Schedule.next ~now_ms:0 ~input:() driver with
    | Some (metadata, next) ->
        Alcotest.(check dur) "second delay" base metadata.delay;
        next
    | None -> Alcotest.fail "fibonacci schedule ended before second delay"
  in
  match Schedule.next ~now_ms:0 ~input:() driver with
  | Some (metadata, _) ->
      Alcotest.(check dur)
        "third delay saturates" (Duration.ms max_int) metadata.delay
  | None -> Alcotest.fail "fibonacci schedule ended on overflow"

let test_schedule_linear_saturates_on_overflow () =
  let driver =
    Schedule.start
      (Schedule.linear ~initial:(Duration.ms 1) ~step:(Duration.ms max_int))
  in
  let driver =
    match Schedule.next ~now_ms:0 ~input:() driver with
    | Some (metadata, next) ->
        Alcotest.(check dur) "first delay" (Duration.ms 1) metadata.delay;
        next
    | None -> Alcotest.fail "linear schedule ended too early"
  in
  match Schedule.next ~now_ms:0 ~input:() driver with
  | Some (metadata, _) ->
      Alcotest.(check dur)
        "second delay saturates" (Duration.ms max_int) metadata.delay
  | None -> Alcotest.fail "linear schedule ended on overflow"

let test_spaced_fixed_linear () =
  Alcotest.(check some_dur) "spaced" (Some (Duration.seconds 1))
    (next_delay (Schedule.spaced (Duration.seconds 1)) ~step:4);
  Alcotest.(check some_dur) "fixed" (Some (Duration.seconds 1))
    (next_delay (Schedule.fixed (Duration.seconds 1)) ~step:4);
  Alcotest.(check some_dur) "linear step 3" (Some (Duration.seconds 7))
    (next_delay
       (Schedule.linear ~initial:(Duration.seconds 1)
          ~step:(Duration.seconds 2))
       ~step:3)

let test_schedule_composition () =
  Alcotest.(check some_dur) "both takes max" (Some (Duration.seconds 2))
    (next_delay
       (Schedule.both (Schedule.spaced (Duration.seconds 1))
          (Schedule.spaced (Duration.seconds 2)))
       ~step:0);
  Alcotest.(check some_dur) "either takes min" (Some (Duration.seconds 1))
    (next_delay
       (Schedule.either (Schedule.spaced (Duration.seconds 1))
          (Schedule.spaced (Duration.seconds 2)))
       ~step:0);
  Alcotest.(check some_dur) "and_then falls through"
    (Some (Duration.seconds 1))
    (next_delay
       (Schedule.and_then (Schedule.recurs 1)
          (Schedule.spaced (Duration.seconds 1)))
       ~step:1)

let test_schedule_composition_termination_with_driver () =
  let collect schedule =
    let rec loop driver acc =
      match Schedule.next ~now_ms:0 ~input:() driver with
      | None -> List.rev acc
      | Some (metadata, next) -> loop next (metadata.delay :: acc)
    in
    loop (Schedule.start schedule) []
  in
  Alcotest.(check (list dur)) "both terminates with shorter side"
    [ Duration.seconds 2; Duration.seconds 2 ]
    (collect
       (Schedule.both
          (Schedule.both (Schedule.recurs 2)
             (Schedule.spaced (Duration.seconds 1)))
          (Schedule.spaced (Duration.seconds 2))));
  Alcotest.(check (list dur)) "either terminates with longer side"
    [ Duration.seconds 1; Duration.seconds 1; Duration.seconds 2 ]
    (collect
       (Schedule.either
          (Schedule.both (Schedule.recurs 2)
             (Schedule.spaced (Duration.seconds 1)))
          (Schedule.both (Schedule.recurs 3)
             (Schedule.spaced (Duration.seconds 2)))));
  Alcotest.(check (list dur)) "and_then runs second phase after first"
    [ Duration.zero; Duration.seconds 1; Duration.seconds 1 ]
    (collect
       (Schedule.and_then (Schedule.recurs 1)
          (Schedule.both (Schedule.recurs 2)
             (Schedule.spaced (Duration.seconds 1)))))

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
        (next_delay exponential ~step))
    [ 0; 1; 2; 3; 4 ];
  Alcotest.(check some_dur) "exponential phase step 0"
    (Some (Duration.seconds 1))
    (next_delay exponential ~step:5);
  Alcotest.(check some_dur) "exponential phase step 1"
    (Some (Duration.seconds 2))
    (next_delay exponential ~step:6);
  Alcotest.(check some_dur) "exponential phase step 2"
    (Some (Duration.seconds 4))
    (next_delay exponential ~step:7);
  let linear =
    Schedule.and_then (Schedule.recurs 3)
      (Schedule.linear ~initial:(Duration.ms 100) ~step:(Duration.ms 50))
  in
  Alcotest.(check some_dur) "linear phase step 0" (Some (Duration.ms 100))
    (next_delay linear ~step:3);
  Alcotest.(check some_dur) "linear phase step 1" (Some (Duration.ms 150))
    (next_delay linear ~step:4);
  let jittered =
    Schedule.and_then (Schedule.recurs 2)
      (Schedule.exponential ~factor:2.0 (Duration.ms 100))
    |> Schedule.jittered ~min:1.0 ~max:1.0
  in
  Alcotest.(check some_dur) "jittered wraps second phase step 0"
    (Some (Duration.ms 100))
    (next_delay jittered ~step:2)

let test_schedule_jittered_uses_random_capability () =
  let random = Capabilities.random_of_seed 17 in
  let schedule =
    Schedule.spaced (Duration.ms 100)
    |> Schedule.jittered ~min:1.0 ~max:2.0
  in
  Alcotest.(check some_dur) "jittered factor from capability"
    (Some (Duration.ms 177))
    (next_delay ~random schedule ~step:0);
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

let test_random_int_in_range_handles_wide_ranges () =
  let random = Capabilities.random_of_seed 7 in
  let value = Random.int_in_range random ~min:min_int ~max:max_int in
  Alcotest.(check bool) "full int range lower bound" true (value >= min_int);
  Alcotest.(check bool) "full int range upper bound" true (value <= max_int);
  Alcotest.(check bool) "wide range does not collapse to min" true
    (value <> min_int)

let test_schedule_jittered_stays_inside_multiplier_bounds () =
  let schedule =
    Schedule.spaced (Duration.ms 100)
    |> Schedule.jittered ~min:0.5 ~max:1.5
  in
  let driver =
    ref (Schedule.start ~random:(Capabilities.random_of_seed 23) schedule)
  in
  for step = 0 to 99 do
    match Schedule.next ~now_ms:0 ~input:() !driver with
    | None -> Alcotest.fail "jittered spaced schedule terminated"
    | Some (metadata, next) ->
        driver := next;
        Alcotest.(check bool)
          ("step " ^ string_of_int step ^ " inside lower bound")
          true
          (Duration.compare metadata.delay (Duration.ms 50) >= 0);
        Alcotest.(check bool)
          ("step " ^ string_of_int step ^ " inside upper bound")
          true
          (Duration.compare metadata.delay (Duration.ms 150) <= 0)
  done

let test_schedule_jittered_exponential_does_not_raise () =
  let schedule =
    Schedule.(
      jittered ~min:1.1 ~max:1.2
        (exponential ~factor:2.0 (Duration.seconds 1)))
  in
  let driver =
    ref (Schedule.start ~random:(Capabilities.random_of_seed 7) schedule)
  in
  for _ = 1 to 80 do
    match Schedule.next ~now_ms:0 ~input:() !driver with
    | Some (_, next_driver) -> driver := next_driver
    | None -> ()
  done;
  Alcotest.(check bool) "advancing the schedule never raised" true true

let test_random_int_in_range_rejects_inverted_bounds () =
  let random = Capabilities.random_of_seed 42 in
  Alcotest.check_raises "int_in_range with inverted bounds must raise"
    (Invalid_argument "Eta.Random.int_in_range: min > max")
    (fun () -> ignore (Random.int_in_range random ~min:10 ~max:5))

let test_random_float_in_range_rejects_inverted_bounds () =
  let random = Capabilities.random_of_seed 42 in
  Alcotest.check_raises "float_in_range with inverted bounds must raise"
    (Invalid_argument "Eta.Random.float_in_range: min > max")
    (fun () -> ignore (Random.float_in_range random ~min:10.0 ~max:5.0))

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

let tests =
  [
    ( "Duration",
      [
        Alcotest.test_case "constructors" `Quick test_duration_constructors;
        Alcotest.test_case "ordering" `Quick test_duration_ordering;
        Alcotest.test_case "algebra" `Quick test_duration_algebra;
        Alcotest.test_case "scale by 1.0 is identity at max" `Quick
          test_duration_scale_identity_at_max;
        Alcotest.test_case "overflow" `Quick test_duration_overflow;
        Alcotest.test_case "min max clamp" `Quick test_duration_min_max_clamp;
        Alcotest.test_case "zero detection and conversion" `Quick
          test_duration_zero_detection_and_conversion;
        Alcotest.test_case "humanize" `Quick test_duration_humanize;
      ] );
    ( "Schedule",
      [
        Alcotest.test_case "recurs" `Quick test_recurs;
        Alcotest.test_case "recurs driver yields exactly n delays" `Quick
          test_recurs_driver_yields_exactly_n_delays;
        Alcotest.test_case "exponential" `Quick test_exponential;
        Alcotest.test_case "exponential saturates on overflow" `Quick
          test_exponential_saturates_on_overflow;
        Alcotest.test_case "fixed uses cadence with now metadata" `Quick
          test_fixed_uses_cadence_with_now_metadata;
        Alcotest.test_case "windowed" `Quick test_windowed;
        Alcotest.test_case "outputs and done decision" `Quick
          test_schedule_outputs_and_done_decision;
        Alcotest.test_case "elapsed accumulates from first step" `Quick
          test_schedule_elapsed_accumulates_from_first_step;
        Alcotest.test_case "during stops after bound" `Quick
          test_schedule_during_stops_after_bound;
        Alcotest.test_case "output predicates and recur_until" `Quick
          test_schedule_output_predicates_and_recur_until;
        Alcotest.test_case "modify_delay" `Quick test_schedule_modify_delay;
        Alcotest.test_case "tap_input and tap_output" `Quick
          test_schedule_taps_input_and_output;
        Alcotest.test_case "fibonacci" `Quick test_fibonacci;
        Alcotest.test_case "fibonacci composes with recurs driver" `Quick
          test_fibonacci_composes_with_recurs_driver;
        Alcotest.test_case "composition outputs" `Quick
          test_schedule_composition_outputs;
        Alcotest.test_case "fibonacci edges" `Quick test_fibonacci_edges;
        Alcotest.test_case "linear saturates on overflow" `Quick
          test_schedule_linear_saturates_on_overflow;
        Alcotest.test_case "spaced fixed linear" `Quick
          test_spaced_fixed_linear;
        Alcotest.test_case "composition" `Quick test_schedule_composition;
        Alcotest.test_case "composition termination with driver" `Quick
          test_schedule_composition_termination_with_driver;
        Alcotest.test_case "and_then offsets second phase" `Quick
          test_schedule_and_then_offsets_second_phase;
        Alcotest.test_case "jittered uses random capability" `Quick
          test_schedule_jittered_uses_random_capability;
        Alcotest.test_case "random int wide ranges" `Quick
          test_random_int_in_range_handles_wide_ranges;
        Alcotest.test_case "jittered stays inside multiplier bounds" `Quick
          test_schedule_jittered_stays_inside_multiplier_bounds;
        Alcotest.test_case "jittered exponential backoff never raises" `Quick
          test_schedule_jittered_exponential_does_not_raise;
        Alcotest.test_case "int_in_range rejects inverted bounds" `Quick
          test_random_int_in_range_rejects_inverted_bounds;
        Alcotest.test_case "float_in_range rejects inverted bounds" `Quick
          test_random_float_in_range_rejects_inverted_bounds;
        Alcotest.test_case "random float distribution and determinism" `Quick
          test_random_float_distribution_and_determinism;
      ] );
  ]
