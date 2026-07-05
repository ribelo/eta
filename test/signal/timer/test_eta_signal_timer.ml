module Timer = Eta_signal_timer
module Timer_policy = Eta_signal_timer_policy

let inactive generation = Timer_policy.inactive_state ~generation

let pp_hidden ppf _ = Format.pp_print_string ppf "<timer-error>"

let run_ok runtime effect =
  match Eta_eio.Runtime.run runtime effect with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected Ok, got %a" (Eta.Cause.pp pp_hidden) cause

let run_error runtime effect =
  match Eta_eio.Runtime.run runtime effect with
  | Eta.Exit.Ok _ -> Alcotest.fail "expected Error, got Ok"
  | Eta.Exit.Error cause -> cause

let with_runtime f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let runtime =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
      ()
  in
  f runtime

type timer = {
  name : string;
  mutable current : Timer_policy.state;
  mutable effective : Timer_policy.state;
}

let make_timer name ~current ~effective = { name; current; effective }

type node_demand_case = {
  case_name : string;
  mutable case_current : Timer_policy.state;
  mutable case_effective : Timer_policy.state;
  mutable case_node : unit Timer.node option;
}

let make_node_demand_case case_name ~current ~effective =
  {
    case_name;
    case_current = current;
    case_effective = effective;
    case_node = None;
  }

let runtime_error = Alcotest.testable Format.pp_print_string String.equal

let state_label state =
  Timer_policy.state_label state
  ^ ":"
  ^ string_of_int (Timer_policy.state_generation state)

let append_event events event = events := !events @ [ event ]

let state_port ?(record = fun _ -> ()) () =
  {
    Timer.state_effective = (fun timer -> timer.effective);
    state_current = (fun timer -> timer.current);
    state_set_current =
      (fun timer state ->
        timer.current <- state;
        timer.effective <- state;
        record ("set:" ^ timer.name ^ ":" ^ state_label state));
  }

let test_refresh_demand_classifies_and_orders_effects () =
  let events = ref [] in
  let record event = append_event events event in
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
      demand_start_effect =
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
        "starts" [ "start:start" ]
        (Timer.start_attempt_effects effects.Timer.demand_start_attempts);
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

let test_refresh_node_demand_owns_node_start_wiring () =
  with_runtime @@ fun runtime ->
  let events = ref [] in
  let record event = append_event events event in
  let running generation label =
    Timer_policy.running_state ~generation ~next_due_ms:(Some 10)
      ~cancel:(fun () -> record ("cancel:" ^ label))
  in
  let start =
    make_node_demand_case "start" ~current:(inactive 0)
      ~effective:(inactive 0)
  in
  let stop =
    make_node_demand_case "stop" ~current:(running 1 "stop")
      ~effective:(running 1 "stop")
  in
  let idle =
    make_node_demand_case "idle" ~current:(inactive 0)
      ~effective:(inactive 0)
  in
  let cases = [ start; stop; idle ] in
  let effect =
    Eta.Effect.Expert.make
      ~leaf_name:"eta_signal.timer.test_node_demand" @@ fun context ->
    let runtime_contract = Eta.Effect.Expert.contract context in
    let find_case timer =
      match
        List.find_opt
          (fun case ->
            match case.case_node with
            | Some node -> node == timer
            | None -> false)
          cases
      with
      | Some case -> case
      | None -> Alcotest.fail "unknown timer node"
    in
    let port =
      {
        Timer.state_effective =
          (fun timer -> (find_case timer).case_effective);
        state_current = (fun timer -> (find_case timer).case_current);
        state_set_current =
          (fun timer state ->
            let case = find_case timer in
            case.case_current <- state;
            case.case_effective <- state;
            record
              ("set:" ^ case.case_name ^ ":" ^ state_label state));
      }
    in
    let make_node case =
      let node =
        Timer.create_node ~runtime_contract
          ~refresh_when_inactive:true ~refresh_operation:None
          ~start:
            {
              Timer.run =
                (fun _timer ->
                  record
                    ("start:" ^ case.case_name ^ ":"
                   ^ state_label case.case_current);
                  Eta.Effect.sync (fun () ->
                      record ("run:" ^ case.case_name)));
            }
      in
      case.case_node <- Some node;
      node
    in
    let start_node = make_node start in
    let stop_node = make_node stop in
    let idle_node = make_node idle in
    match
      Timer.refresh_node_demand ~advance_generation:succ
        ~cancel_running:true
        {
          Timer.node_demand_necessary = [ 1 ];
          node_demand_timers =
            [ (1, start_node); (2, stop_node); (3, idle_node) ];
          node_demand_is_necessary =
            (fun necessary id -> List.exists (( = ) id) necessary);
          node_demand_validate_runtime =
            (fun actual_runtime timer ->
              let case = find_case timer in
              record ("validate:" ^ case.case_name);
              if
                Eta.Runtime_contract.same_runtime actual_runtime
                  (Timer.runtime_contract timer)
              then Ok ()
              else Error `Runtime_mismatch);
          node_demand_state = port;
        }
        runtime_contract
    with
    | Error `Runtime_mismatch -> Alcotest.fail "unexpected runtime mismatch"
    | Ok effects ->
        Alcotest.(check (list string))
          "construction events"
          [
            "validate:start";
            "set:start:starting:1";
            "start:start:starting:1";
            "set:stop:inactive:2";
          ]
          !events;
        Alcotest.(check int)
          "start attempts" 1
          (List.length
             (Timer.start_attempt_effects
                effects.Timer.demand_start_attempts));
        Alcotest.(check int)
          "cancel hooks" 1
          (List.length effects.Timer.demand_cancel_hooks);
        List.iter (fun hook -> hook ()) effects.Timer.demand_cancel_hooks;
        (match
           Eta.Effect.Expert.eval context
             (Eta.Effect.concat
                (Timer.start_attempt_effects
                   effects.Timer.demand_start_attempts))
         with
        | Eta.Exit.Ok () ->
            Alcotest.(check (list string))
              "events"
              [
                "validate:start";
                "set:start:starting:1";
                "start:start:starting:1";
                "set:stop:inactive:2";
                "cancel:stop";
                "run:start";
              ]
              !events;
            Eta.Exit.Ok ()
        | Eta.Exit.Error _ as exit -> exit)
  in
  run_ok runtime effect

let test_refresh_node_demand_effect_owns_node_bracketing () =
  with_runtime @@ fun runtime ->
  let events = ref [] in
  let record event = append_event events event in
  let running generation label =
    Timer_policy.running_state ~generation ~next_due_ms:(Some 10)
      ~cancel:(fun () -> record ("cancel:" ^ label))
  in
  let start =
    make_node_demand_case "start" ~current:(inactive 0)
      ~effective:(inactive 0)
  in
  let stop =
    make_node_demand_case "stop" ~current:(running 1 "stop")
      ~effective:(running 1 "stop")
  in
  let cases = [ start; stop ] in
  let find_case timer =
    match
      List.find_opt
        (fun case ->
          match case.case_node with
          | Some node -> node == timer
          | None -> false)
        cases
    with
    | Some case -> case
    | None -> Alcotest.fail "unknown timer node"
  in
  let port =
    {
      Timer.state_effective =
        (fun timer -> (find_case timer).case_effective);
      state_current = (fun timer -> (find_case timer).case_current);
      state_set_current =
        (fun timer state ->
          let case = find_case timer in
          case.case_current <- state;
          case.case_effective <- state;
          record ("set:" ^ case.case_name ^ ":" ^ state_label state));
    }
  in
  let make_node runtime_contract case =
    let node =
      Timer.create_node ~runtime_contract ~refresh_when_inactive:true
        ~refresh_operation:None
        ~start:
          {
            Timer.run =
              (fun _timer ->
                record
                  ("start:" ^ case.case_name ^ ":"
                 ^ state_label case.case_current);
                Eta.Effect.sync (fun () ->
                    record ("run:" ^ case.case_name)));
          }
    in
    case.case_node <- Some node;
    node
  in
  let nodes runtime_contract =
    match (start.case_node, stop.case_node) with
    | Some start_node, Some stop_node -> (start_node, stop_node)
    | _ ->
        let start_node = make_node runtime_contract start in
        let stop_node = make_node runtime_contract stop in
        (start_node, stop_node)
  in
  run_ok runtime
    (Timer.refresh_node_demand_effect ~advance_generation:succ
       {
         Timer.demand_with_access =
           (fun f ->
             Eta.Effect.sync (fun () ->
                 record "access";
                 f ())
             |> Eta.Effect.flatten_result);
       }
       {
         Timer.node_demand_effect_acquire =
           (fun runtime_contract () ->
             record "acquire";
             let start_node, stop_node = nodes runtime_contract in
             Timer.refresh_node_demand ~advance_generation:succ
               ~cancel_running:true
               {
                 Timer.node_demand_necessary = [ 1 ];
                 node_demand_timers = [ (1, start_node); (2, stop_node) ];
                 node_demand_is_necessary =
                   (fun necessary id -> List.exists (( = ) id) necessary);
                 node_demand_validate_runtime =
                   (fun actual_runtime timer ->
                     let case = find_case timer in
                     record ("validate:" ^ case.case_name);
                     if
                       Eta.Runtime_contract.same_runtime actual_runtime
                         (Timer.runtime_contract timer)
                     then Ok ()
                     else Error `Runtime_mismatch);
                 node_demand_state = port;
               }
               runtime_contract);
         node_demand_effect_state = port;
       });
  Alcotest.(check (list string))
    "events"
    [
      "access";
      "acquire";
      "validate:start";
      "set:start:starting:1";
      "start:start:starting:1";
      "set:stop:inactive:2";
      "cancel:stop";
      "run:start";
      "access";
      "set:start:inactive:2";
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
      demand_start_effect =
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
  let record event = append_event events event in
  let starting =
    make_timer "starting"
      ~current:(Timer_policy.starting_state ~generation:4)
      ~effective:(Timer_policy.starting_state ~generation:4)
  in
  let inactive_timer =
    make_timer "inactive" ~current:(inactive 9) ~effective:(inactive 9)
  in
  let starting_hooks =
    Timer.rollback_unclaimed_start ~advance_generation:succ
      (state_port ~record ()) starting
  in
  let inactive_hooks =
    Timer.rollback_unclaimed_start ~advance_generation:succ
      (state_port ~record ()) inactive_timer
  in
  Alcotest.(check (list string))
    "events" [ "set:starting:inactive:5" ] !events;
  Alcotest.(check int) "starting hooks" 0 (List.length starting_hooks);
  Alcotest.(check int) "inactive hooks" 0 (List.length inactive_hooks);
  Alcotest.(check string) "starting state" "inactive:5"
    (state_label starting.current);
  Alcotest.(check string) "inactive state" "inactive:9"
    (state_label inactive_timer.current)

let test_rollback_unclaimed_start_attempts_hide_timer_pairing () =
  let events = ref [] in
  let record event = append_event events event in
  let starting =
    make_timer "starting"
      ~current:(inactive 4) ~effective:(inactive 4)
  in
  let attempts, cancel_hooks =
    let port =
      {
        Timer.demand_collect_necessary = (fun () -> [ 1 ]);
        demand_collect_timers = (fun () -> [ (1, starting) ]);
        demand_is_necessary =
          (fun necessary id -> List.exists (( = ) id) necessary);
        demand_validate_runtime = (fun _runtime _timer -> Ok ());
        demand_effective_state = (fun timer -> timer.effective);
        demand_current_state = (fun timer -> timer.current);
        demand_set_current_state =
          (fun timer state ->
            timer.current <- state;
            timer.effective <- state;
            record ("set:" ^ timer.name ^ ":" ^ state_label state));
        demand_start_effect = (fun _timer -> "start-effect");
      }
    in
    match
      Timer.refresh_demand ~advance_generation:succ ~cancel_running:true
        port "rt"
    with
    | Error error -> Alcotest.failf "unexpected error %s" error
    | Ok effects ->
        ( effects.Timer.demand_start_attempts,
          effects.Timer.demand_cancel_hooks )
  in
  let hooks =
    Timer.rollback_unclaimed_start_attempts ~advance_generation:succ
      (state_port ~record ()) attempts
  in
  Alcotest.(check (list string))
    "effects" [ "start-effect" ]
    (Timer.start_attempt_effects attempts);
  Alcotest.(check (list string))
    "events" [ "set:starting:starting:5"; "set:starting:inactive:6" ]
    !events;
  Alcotest.(check int) "refresh hooks" 0 (List.length cancel_hooks);
  Alcotest.(check int) "hooks" 0 (List.length hooks);
  Alcotest.(check string) "starting state" "inactive:6"
    (state_label starting.current)

let test_daemon_lifecycle_transitions () =
  let events = ref [] in
  let record event = append_event events event in
  let cancelled = ref false in
  let timer =
    make_timer "daemon"
      ~current:(Timer_policy.starting_state ~generation:4)
      ~effective:(Timer_policy.starting_state ~generation:4)
  in
  let port = state_port ~record () in
  Alcotest.(check bool) "begin starts" true
    (match Timer.begin_start port timer ~generation:4 with
    | `Continue -> true
    | `Stop -> false);
  Alcotest.(check string) "uncancellable" "running_uncancellable:4"
    (state_label timer.current);
  Alcotest.(check bool) "install cancel continues" true
    (match
       Timer.install_cancel port timer ~generation:4
         ~cancel:(fun () -> cancelled := true)
     with
    | `Continue -> true
    | `Stop -> false);
  Alcotest.(check bool) "has cancel" true
    (Timer_policy.state_has_cancel timer.current);
  Alcotest.(check bool) "running continues" true
    (match Timer.after_update_state port timer ~generation:4 with
    | `Continue -> true
    | `Stop -> false);
  Alcotest.(check bool) "stale generation stops" true
    (match Timer.after_update_state port timer ~generation:3 with
    | `Stop -> true
    | `Continue -> false);
  Alcotest.(check bool) "cleanup advances failed daemon" true
    (Timer.cleanup_after_exit ~advance_generation:succ port timer
       ~generation:4 Timer_policy.Daemon_error;
     Timer_policy.state_generation timer.current = 5);
  Alcotest.(check bool) "cancel not run by cleanup" false !cancelled;
  Alcotest.(check (list string))
    "events"
    [
      "set:daemon:running_uncancellable:4";
      "set:daemon:running:4";
      "set:daemon:inactive:5";
    ]
    !events

let test_due_lifecycle_transitions () =
  let events = ref [] in
  let record event = append_event events event in
  let timer =
    make_timer "due"
      ~current:
        (Timer_policy.running_uncancellable_state ~generation:2
           ~next_due_ms:(Some 10))
      ~effective:
        (Timer_policy.running_uncancellable_state ~generation:2
           ~next_due_ms:(Some 10))
  in
  let port = state_port ~record () in
  Alcotest.(check (option int))
    "read due" (Some 10)
    (Timer.read_next_due port timer ~generation:2 ~fallback:5);
  Alcotest.(check bool) "set due" true
    (match Timer.set_next_due port timer ~generation:2 ~next_due_ms:20 with
    | `Continue -> true
    | `Stop -> false);
  Alcotest.(check bool) "advance due" true
    (match
       Timer.advance_next_due port timer ~generation:2 ~expected:20
         ~next_due_ms:30
     with
    | `Advanced -> true
    | `Stale | `Stop -> false);
  let published = ref false in
  Alcotest.(check bool) "publish running" true
    (match
       Timer.publish_if_running port timer ~generation:2 ~publish:(fun () ->
           published := true)
     with
    | `Updated -> true
    | `Stopped -> false);
  Alcotest.(check bool) "published" true !published;
  Timer.finish_saturated ~advance_generation:succ port timer ~generation:2;
  Alcotest.(check string) "finished" "finished:3"
    (state_label timer.current);
  Alcotest.(check bool) "publish stopped" true
    (match
       Timer.publish_if_running port timer ~generation:2 ~publish:(fun () ->
           Alcotest.fail "stopped timer published")
     with
    | `Stopped -> true
    | `Updated -> false);
  Alcotest.(check (list string))
    "events"
    [
      "set:due:running_uncancellable:2";
      "set:due:running_uncancellable:2";
      "set:due:finished:3";
    ]
    !events

let timer_demand_access events =
  {
    Timer.demand_with_access =
      (fun f ->
        Eta.Effect.sync (fun () ->
            append_event events "access";
            f "capability")
        |> Eta.Effect.flatten_result);
  }

let test_refresh_demand_effect_owns_adapter_bracketing () =
  with_runtime @@ fun runtime ->
  let events = ref [] in
  run_ok runtime
    (Timer.refresh_demand_effect (timer_demand_access events)
       {
         Timer.demand_acquire =
           (fun _runtime_contract capability ->
             append_event events ("acquire:" ^ capability);
             Ok
               {
                 Timer.demand_start_attempts = [ "start-a"; "start-b" ];
                 demand_cancel_hooks =
                   [
                     (fun () -> append_event events "cancel:acquire-a");
                     (fun () -> append_event events "cancel:acquire-b");
                   ];
               });
         demand_rollback_unclaimed =
           (fun capability attempts ->
             append_event events ("rollback:" ^ capability);
             List.iter
               (fun attempt ->
                 append_event events ("rollback-start:" ^ attempt))
               attempts;
             Ok [ (fun () -> append_event events "cancel:rollback") ]);
         demand_run_cancel_hooks =
           (fun hooks ->
             Eta.Effect.sync (fun () ->
                 List.iter (fun hook -> hook ()) hooks));
         demand_run_start_attempts =
           (fun attempts ->
             Eta.Effect.sync (fun () ->
                 List.iter
                   (fun attempt -> append_event events ("start:" ^ attempt))
                   attempts));
       });
  Alcotest.(check (list string))
    "events"
    [
      "access";
      "acquire:capability";
      "cancel:acquire-a";
      "cancel:acquire-b";
      "start:start-a";
      "start:start-b";
      "access";
      "rollback:capability";
      "rollback-start:start-a";
      "rollback-start:start-b";
      "cancel:rollback";
    ]
    !events

let test_refresh_demand_effect_acquire_failure_skips_release () =
  with_runtime @@ fun runtime ->
  let events = ref [] in
  let cause =
    run_error runtime
      (Timer.refresh_demand_effect (timer_demand_access events)
         {
           Timer.demand_acquire =
             (fun _runtime_contract capability ->
               append_event events ("acquire:" ^ capability);
               Error `Demand_failed);
           demand_rollback_unclaimed =
             (fun _capability _attempts ->
               append_event events "rollback";
               Ok []);
           demand_run_cancel_hooks =
             (fun _hooks ->
               Eta.Effect.sync (fun () -> append_event events "cancel"));
           demand_run_start_attempts =
             (fun _attempts ->
               Eta.Effect.sync (fun () -> append_event events "start"));
         })
  in
  (match Eta.Cause.failures cause with
  | [ `Demand_failed ] -> ()
  | _ ->
      Alcotest.failf "expected Demand_failed, got %a"
        (Eta.Cause.pp (fun ppf `Demand_failed ->
             Format.pp_print_string ppf "Demand_failed"))
        cause);
  Alcotest.(check (list string))
    "events" [ "access"; "acquire:capability" ] !events

let daemon_context events port update =
  {
    Timer.daemon_advance_generation = succ;
    daemon_state_access =
      {
        Timer.daemon_with_state =
          (fun f ->
            Eta.Effect.sync (fun () ->
                append_event events "access";
                f ()));
      };
    daemon_state = port;
    daemon_update = update;
    daemon_hooks =
      {
        Timer.daemon_after_due_read_before_commit =
          (fun () ->
            Eta.Effect.sync (fun () -> append_event events "due_hook"));
        daemon_after_update_constructed_before_run =
          (fun () ->
            Eta.Effect.sync (fun () -> append_event events "after_update"));
      };
  }

let test_start_daemon_wires_start_update_through_timer_port () =
  with_runtime @@ fun runtime ->
  let events = ref [] in
  let timer =
    make_timer "daemon"
      ~current:(Timer_policy.starting_state ~generation:3)
      ~effective:(Timer_policy.starting_state ~generation:3)
  in
  let port =
    {
      Timer.state_effective = (fun timer -> timer.effective);
      state_current = (fun timer -> timer.current);
      state_set_current =
        (fun timer state ->
          timer.current <- state;
          append_event events ("set:" ^ state_label state));
    }
  in
  run_ok runtime
    (Timer.start_daemon
       (daemon_context events port
          {
            Timer.daemon_update =
              (fun _timer ~generation ~missed ->
                Eta.Effect.sync (fun () ->
                    append_event events
                      ("update:" ^ string_of_int generation ^ ":"
                     ^ string_of_int missed)));
          })
       timer
       ~generation:3 ~interval_ms:10 ~update_on_start:true
       ~catch_up_policy:Timer_policy.Catch_up_coalesced);
  Alcotest.(check (list string))
    "events"
    [
      "access";
      "set:running_uncancellable:3";
      "update:3:1";
      "access";
      "access";
    ]
    !events;
  Alcotest.(check string) "state" "running_uncancellable:3"
    (state_label timer.current)

let test_create_daemon_node_owns_start_effect_generation () =
  with_runtime @@ fun runtime ->
  let events = ref [] in
  let current = ref (Timer_policy.starting_state ~generation:6) in
  let effective = ref (Timer_policy.starting_state ~generation:6) in
  let port =
    {
      Timer.state_effective = (fun _timer -> !effective);
      state_current = (fun _timer -> !current);
      state_set_current =
        (fun _timer state ->
          current := state;
          append_event events ("set:" ^ state_label state));
    }
  in
  let effect =
    Eta.Effect.Expert.make ~leaf_name:"eta_signal.timer.test_node"
    @@ fun context ->
    let runtime_contract = Eta.Effect.Expert.contract context in
    let timer =
      Timer.create_daemon_node ~runtime_contract ~refresh_when_inactive:true
        ~refresh_operation:None
        (daemon_context events port
           {
             Timer.daemon_update =
               (fun _timer ~generation ~missed ->
                 Eta.Effect.sync (fun () ->
                     append_event events
                       ("update:" ^ string_of_int generation ^ ":"
                      ^ string_of_int missed)));
           })
        ~interval_ms:10 ~update_on_start:true
        ~catch_up_policy:Timer_policy.Catch_up_coalesced
    in
    Alcotest.(check bool)
      "runtime contract"
      true
      (Eta.Runtime_contract.same_runtime
         (Timer.runtime_contract timer)
         runtime_contract);
    Eta.Effect.Expert.eval context (Timer.start_effect timer)
  in
  run_ok runtime effect;
  Alcotest.(check (list string))
    "events"
    [
      "access";
      "set:running_uncancellable:6";
      "update:6:1";
      "access";
      "access";
    ]
    !events;
  Alcotest.(check string) "state" "running_uncancellable:6"
    (state_label !current)

let () =
  Alcotest.run "eta_signal_timer"
    [
      ( "demand",
        [
          Alcotest.test_case "classifies and orders effects" `Quick
            test_refresh_demand_classifies_and_orders_effects;
          Alcotest.test_case "node helper owns start wiring" `Quick
            test_refresh_node_demand_owns_node_start_wiring;
          Alcotest.test_case "node effect helper owns bracketing" `Quick
            test_refresh_node_demand_effect_owns_node_bracketing;
          Alcotest.test_case "validation failure short-circuits" `Quick
            test_refresh_demand_validation_failure_short_circuits;
          Alcotest.test_case "rolls back unclaimed starts" `Quick
            test_rollback_unclaimed_start_marks_starting_unneeded;
          Alcotest.test_case "rolls back start attempts" `Quick
            test_rollback_unclaimed_start_attempts_hide_timer_pairing;
          Alcotest.test_case "daemon lifecycle transitions" `Quick
            test_daemon_lifecycle_transitions;
          Alcotest.test_case "due lifecycle transitions" `Quick
            test_due_lifecycle_transitions;
          Alcotest.test_case "effect bracketing" `Quick
            test_refresh_demand_effect_owns_adapter_bracketing;
          Alcotest.test_case "effect acquire failure skips release" `Quick
            test_refresh_demand_effect_acquire_failure_skips_release;
          Alcotest.test_case "start daemon callback ownership" `Quick
            test_start_daemon_wires_start_update_through_timer_port;
          Alcotest.test_case "daemon node start ownership" `Quick
            test_create_daemon_node_owns_start_effect_generation;
        ] );
    ]
