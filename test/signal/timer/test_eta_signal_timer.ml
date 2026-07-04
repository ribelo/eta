module Timer = Eta_signal_timer
module Timer_policy = Eta_signal_timer_policy

let noop () = ()
let inactive generation = Timer_policy.inactive_state ~generation

let running generation =
  Timer_policy.running_state ~generation ~next_due_ms:(Some 10) ~cancel:noop

let runtime_error = Alcotest.testable Format.pp_print_string String.equal

let test_refresh_demand_classifies_and_orders_effects () =
  let events = ref [] in
  let record event = events := !events @ [ event ] in
  let state = function
    | "start" -> inactive 0
    | "stop" -> running 1
    | "idle" -> inactive 0
    | timer -> Alcotest.failf "unexpected timer %s" timer
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
          [ (1, "start"); (2, "stop"); (3, "idle") ]);
      demand_is_necessary =
        (fun necessary id -> List.exists (( = ) id) necessary);
      demand_validate_runtime =
        (fun runtime timer ->
          record ("validate:" ^ runtime ^ ":" ^ timer);
          Ok ());
      demand_effective_state = state;
      demand_current_state = state;
      demand_plan_start =
        (fun timer plan ->
          record
            ("start:" ^ timer ^ ":"
           ^ string_of_int plan.Timer_policy.start_generation);
          timer ^ ":start");
      demand_plan_stop =
        (fun timer plan ->
          record
            ("stop:" ^ timer ^ ":"
           ^ string_of_int
               (Timer_policy.state_generation plan.Timer_policy.stop_state));
          [ timer ^ ":hook" ]);
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
          "start:start:1";
          "stop:stop:2";
        ]
        !events;
      Alcotest.(check (list string))
        "starts" [ "start:start" ] effects.Timer.demand_start_attempts;
      Alcotest.(check (list string))
        "hooks" [ "stop:hook" ] effects.Timer.demand_cancel_hooks

let test_refresh_demand_validation_failure_short_circuits () =
  let started = ref false in
  let stopped = ref false in
  let port =
    {
      Timer.demand_collect_necessary = (fun () -> [ 1 ]);
      demand_collect_timers = (fun () -> [ (1, "bad"); (2, "unreached") ]);
      demand_is_necessary =
        (fun necessary id -> List.exists (( = ) id) necessary);
      demand_validate_runtime = (fun _runtime _timer -> Error "runtime");
      demand_effective_state = (fun _timer -> inactive 0);
      demand_current_state = (fun _timer -> inactive 0);
      demand_plan_start =
        (fun _timer _plan ->
          started := true;
          "started");
      demand_plan_stop =
        (fun _timer _plan ->
          stopped := true;
          [ "stopped" ]);
    }
  in
  Alcotest.(check (result reject runtime_error))
    "runtime validation failure" (Error "runtime")
    (Timer.refresh_demand ~advance_generation:succ ~cancel_running:true port
       "rt");
  Alcotest.(check bool) "no start effects" false !started;
  Alcotest.(check bool) "no stop effects" false !stopped

let () =
  Alcotest.run "eta_signal_timer"
    [
      ( "demand",
        [
          Alcotest.test_case "classifies and orders effects" `Quick
            test_refresh_demand_classifies_and_orders_effects;
          Alcotest.test_case "validation failure short-circuits" `Quick
            test_refresh_demand_validation_failure_short_circuits;
        ] );
    ]
