module Timer = Eta_signal_timer
module Timer_policy = Eta_signal_timer_policy

let inactive generation = Timer_policy.inactive_state ~generation

type timer = {
  name : string;
  mutable current : Timer_policy.state;
  effective : Timer_policy.state;
}

let make_timer name ~current ~effective = { name; current; effective }

let runtime_error = Alcotest.testable Format.pp_print_string String.equal

let state_label state =
  Timer_policy.state_label state
  ^ ":"
  ^ string_of_int (Timer_policy.state_generation state)

let test_refresh_demand_classifies_and_orders_effects () =
  let events = ref [] in
  let record event = events := !events @ [ event ] in
  let running generation label =
    Timer_policy.running_state ~generation ~next_due_ms:(Some 10)
      ~cancel:(fun () -> record ("cancel:" ^ label))
  in
  let start =
    make_timer "start" ~current:(inactive 0) ~effective:(inactive 0)
  in
  let stop =
    make_timer "stop" ~current:(running 1 "stop")
      ~effective:(running 1 "stop")
  in
  let idle =
    make_timer "idle" ~current:(inactive 0) ~effective:(inactive 0)
  in
  let port =
    {
      Timer.demand_collect_necessary =
        (fun () ->
          record "collect_necessary";
          [ 1 ]);
      demand_collect_timers =
        (fun () ->
          record "collect_timers";
          [ (1, start); (2, stop); (3, idle) ]);
      demand_is_necessary =
        (fun necessary id -> List.exists (( = ) id) necessary);
      demand_validate_runtime =
        (fun runtime timer ->
          record ("validate:" ^ runtime ^ ":" ^ timer.name);
          Ok ());
      demand_effective_state = (fun timer -> timer.effective);
      demand_current_state = (fun timer -> timer.current);
      demand_set_current_state =
        (fun timer state ->
          timer.current <- state;
          record ("set:" ^ timer.name ^ ":" ^ state_label state));
      demand_start_attempt =
        (fun timer ->
          record ("start:" ^ timer.name ^ ":" ^ state_label timer.current);
          timer.name ^ ":start");
    }
  in
  match
    Timer.refresh_demand ~advance_generation:succ ~cancel_running:true port
      "rt"
  with
  | Error error -> Alcotest.failf "unexpected error %s" error
  | Ok effects ->
      Alcotest.(check (list string))
        "events"
        [
          "collect_necessary";
          "collect_timers";
          "validate:rt:start";
          "set:start:starting:1";
          "start:start:starting:1";
          "set:stop:inactive:2";
        ]
        !events;
      Alcotest.(check (list string))
        "starts" [ "start:start" ] effects.Timer.demand_start_attempts;
      List.iter (fun hook -> hook ()) effects.Timer.demand_cancel_hooks;
      Alcotest.(check (list string))
        "hooks"
        [
          "collect_necessary";
          "collect_timers";
          "validate:rt:start";
          "set:start:starting:1";
          "start:start:starting:1";
          "set:stop:inactive:2";
          "cancel:stop";
        ]
        !events

let test_refresh_demand_validation_failure_short_circuits () =
  let changed_state = ref false in
  let started = ref false in
  let bad =
    make_timer "bad" ~current:(inactive 0) ~effective:(inactive 0)
  in
  let unreached =
    make_timer "unreached" ~current:(inactive 0) ~effective:(inactive 0)
  in
  let port =
    {
      Timer.demand_collect_necessary = (fun () -> [ 1 ]);
      demand_collect_timers = (fun () -> [ (1, bad); (2, unreached) ]);
      demand_is_necessary =
        (fun necessary id -> List.exists (( = ) id) necessary);
      demand_validate_runtime = (fun _runtime _timer -> Error "runtime");
      demand_effective_state = (fun timer -> timer.effective);
      demand_current_state = (fun timer -> timer.current);
      demand_set_current_state =
        (fun _timer _state -> changed_state := true);
      demand_start_attempt =
        (fun _timer ->
          started := true;
          "started");
    }
  in
  Alcotest.(check (result reject runtime_error))
    "runtime validation failure" (Error "runtime")
    (Timer.refresh_demand ~advance_generation:succ ~cancel_running:true port
       "rt");
  Alcotest.(check bool) "no state changes" false !changed_state;
  Alcotest.(check bool) "no start effects" false !started;
  Alcotest.(check string) "bad state unchanged" "inactive:0"
    (state_label bad.current)

let test_rollback_unclaimed_start_marks_starting_unneeded () =
  let events = ref [] in
  let record event = events := !events @ [ event ] in
  let starting =
    make_timer "starting"
      ~current:(Timer_policy.starting_state ~generation:4)
      ~effective:(Timer_policy.starting_state ~generation:4)
  in
  let inactive_timer =
    make_timer "inactive" ~current:(inactive 9) ~effective:(inactive 9)
  in
  let current_state timer = timer.current in
  let set_current_state timer state =
    timer.current <- state;
    record ("set:" ^ timer.name ^ ":" ^ state_label state)
  in
  let starting_hooks =
    Timer.rollback_unclaimed_start ~advance_generation:succ ~current_state
      ~set_current_state starting
  in
  let inactive_hooks =
    Timer.rollback_unclaimed_start ~advance_generation:succ ~current_state
      ~set_current_state inactive_timer
  in
  Alcotest.(check (list string))
    "events" [ "set:starting:inactive:5" ] !events;
  Alcotest.(check int) "starting hooks" 0 (List.length starting_hooks);
  Alcotest.(check int) "inactive hooks" 0 (List.length inactive_hooks);
  Alcotest.(check string) "starting state" "inactive:5"
    (state_label starting.current);
  Alcotest.(check string) "inactive state" "inactive:9"
    (state_label inactive_timer.current)

let () =
  Alcotest.run "eta_signal_timer"
    [
      ( "demand",
        [
          Alcotest.test_case "classifies and orders effects" `Quick
            test_refresh_demand_classifies_and_orders_effects;
          Alcotest.test_case "validation failure short-circuits" `Quick
            test_refresh_demand_validation_failure_short_circuits;
          Alcotest.test_case "rolls back unclaimed starts" `Quick
            test_rollback_unclaimed_start_marks_starting_unneeded;
        ] );
    ]
