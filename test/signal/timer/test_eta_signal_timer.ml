module Timer = Eta_signal_timer
module Timer_policy = Eta_signal_timer_policy

let inactive generation = Timer_policy.inactive_state ~generation

let pp_hidden ppf _ = Format.pp_print_string ppf "<timer-error>"

let run_ok runtime effect =
  match Eta_eio.Runtime.run runtime effect with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected Ok, got %a" (Eta.Cause.pp pp_hidden) cause

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

let with_runtime_and_foreign_contract f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let eio_clock = Eio.Stdenv.clock env in
  let runtime =
    Eta_eio.Runtime.create ~sw ~clock:eio_clock
      ~sleep:(Eta_test.Test_clock.sleep clock)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
      ()
  in
  let foreign_contract =
    Eta.Runtime_contract.of_runtime
      (Eta_eio.runtime ~sw ~clock:eio_clock)
  in
  f runtime foreign_contract

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

let state_label state =
  Timer_policy.state_label state
  ^ ":"
  ^ string_of_int (Timer_policy.state_generation state)

let append_event events event = events := !events @ [ event ]

let state_port ?(record = fun _ -> ()) () =
  Timer.state_port
    ~effective:(fun timer -> timer.effective)
    ~current:(fun timer -> timer.current)
    ~set_current:(fun timer state ->
      timer.current <- state;
      timer.effective <- state;
      record ("set:" ^ timer.name ^ ":" ^ state_label state))

let demand_effect_parts effects =
  Timer.demand_effects_plan effects ~plan:(fun ~start_attempts
      ~cancel_hooks -> (start_attempts, cancel_hooks))

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
      Timer.state_port
        ~effective:(fun timer -> (find_case timer).case_effective)
        ~current:(fun timer -> (find_case timer).case_current)
        ~set_current:(fun timer state ->
          let case = find_case timer in
          case.case_current <- state;
          case.case_effective <- state;
          record ("set:" ^ case.case_name ^ ":" ^ state_label state))
    in
    let make_node case =
      let node =
        Timer.create_node ~runtime_contract
          ~refresh_when_inactive:true ~refresh_operation:None
          ~start:
            (Timer.start ~run:(fun _timer ->
                 record
                   ("start:" ^ case.case_name ^ ":"
                  ^ state_label case.case_current);
                 Eta.Effect.sync (fun () ->
                     record ("run:" ^ case.case_name))))
      in
      case.case_node <- Some node;
      node
    in
    let start_node = make_node start in
    let stop_node = make_node stop in
    let idle_node = make_node idle in
    let plan =
      Timer.node_demand_plan
        ~timers:[ (1, start_node); (2, stop_node); (3, idle_node) ]
        ~is_necessary:(fun id -> id = 1)
        ~runtime_mismatch:
          (fun _actual_runtime timer ->
            let case = find_case timer in
            record ("mismatch:" ^ case.case_name);
            `Runtime_mismatch)
        ~state:port
    in
    match
      Timer.refresh_node_demand_plan ~advance_generation:succ
        ~cancel_running:true plan runtime_contract
    with
    | Error `Runtime_mismatch -> Alcotest.fail "unexpected runtime mismatch"
    | Ok effects ->
        let start_attempts, cancel_hooks = demand_effect_parts effects in
        Alcotest.(check (list string))
          "construction events"
          [
            "set:start:starting:1";
            "start:start:starting:1";
            "set:stop:inactive:2";
          ]
          !events;
        Alcotest.(check int)
          "start attempts" 1
          (List.length (Timer.start_attempt_effects start_attempts));
        Alcotest.(check int)
          "cancel hooks" 1 (List.length cancel_hooks);
        List.iter (fun hook -> hook ()) cancel_hooks;
        (match
           Eta.Effect.Expert.eval context
             (Eta.Effect.concat (Timer.start_attempt_effects start_attempts))
         with
        | Eta.Exit.Ok () ->
            Alcotest.(check (list string))
              "events"
              [
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

let test_node_demand_refresh_owns_node_bracketing () =
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
    Timer.state_port
      ~effective:(fun timer -> (find_case timer).case_effective)
      ~current:(fun timer -> (find_case timer).case_current)
      ~set_current:(fun timer state ->
        let case = find_case timer in
        case.case_current <- state;
        case.case_effective <- state;
        record ("set:" ^ case.case_name ^ ":" ^ state_label state))
  in
  let make_node runtime_contract case =
    let node =
      Timer.create_node ~runtime_contract ~refresh_when_inactive:true
        ~refresh_operation:None
        ~start:
          (Timer.start ~run:(fun _timer ->
               record
                 ("start:" ^ case.case_name ^ ":"
                ^ state_label case.case_current);
               Eta.Effect.sync (fun () ->
                   record ("run:" ^ case.case_name))))
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
  let refresh =
    Timer.node_demand_refresh ~advance_generation:succ
      ~access:
        (Timer.demand_effect_access ~with_access:(fun f ->
             Eta.Effect.sync (fun () ->
                 record "access";
                 f ())
             |> Eta.Effect.flatten_result))
      ~demand:
        (Timer.node_demand_effect_port
           ~plan:(fun runtime_contract () ->
              record "acquire";
              let start_node, stop_node = nodes runtime_contract in
              Timer.node_demand_plan
                ~timers:[ (1, start_node); (2, stop_node) ]
                ~is_necessary:(fun id -> id = 1)
                ~runtime_mismatch:
                  (fun _actual_runtime timer ->
                    let case = find_case timer in
                    record ("mismatch:" ^ case.case_name);
                    `Runtime_mismatch)
                ~state:port))
  in
  run_ok runtime (Timer.run_node_demand_refresh refresh);
  Alcotest.(check (list string))
    "events"
    [
      "access";
      "acquire";
      "set:start:starting:1";
      "start:start:starting:1";
      "set:stop:inactive:2";
      "cancel:stop";
      "run:start";
      "access";
      "set:start:inactive:2";
    ]
    !events

let test_refresh_node_on_demand_owns_validation_and_token_order () =
  with_runtime_and_foreign_contract @@ fun runtime foreign_contract ->
  let active =
    Timer_policy.running_uncancellable_state ~generation:1
      ~next_due_ms:None
  in
  let inactive = inactive 1 in
  let cases =
    [
      ( "allowed active",
        Some "op",
        false,
        0,
        -1,
        active,
        true,
        Ok (),
        [ "remember"; "now"; "run:op:42" ] );
      ("no operation", None, true, 0, -1, active, true, Ok (), []);
      ( "inactive without permission",
        Some "op",
        false,
        0,
        -1,
        inactive,
        true,
        Ok (),
        [] );
      ( "stale current token",
        Some "op",
        true,
        1,
        -1,
        active,
        true,
        Ok (),
        [] );
      ( "runtime failure",
        Some "op",
        true,
        0,
        -1,
        active,
        false,
        Error "runtime",
        [ "mismatch" ] );
    ]
  in
  List.iter
    (fun
      ( name,
        operation,
        refresh_when_inactive,
        current_token,
        staged_token,
        effective_state,
        runtime_matches,
        expected_result,
        expected_events )
    ->
      let events = ref [] in
      let record event = append_event events event in
      let result =
        run_ok runtime
          (Eta.Effect.Expert.make
             ~leaf_name:"eta_signal.timer.test_refresh_node_on_demand"
          @@ fun context ->
            let runtime_contract = Eta.Effect.Expert.contract context in
            let node_runtime_contract =
              if runtime_matches then runtime_contract else foreign_contract
            in
            let node =
              Timer.create_node ~runtime_contract:node_runtime_contract
                ~refresh_when_inactive ~refresh_operation:operation
                ~start:(Timer.start ~run:(fun _timer -> Eta.Effect.unit))
            in
            Timer.set_staged_refresh_token node staged_token;
            let refresh_context =
              Timer_policy.create_refresh_context ~token:1
                ~runtime_contract
                ~now_ms:(fun () ->
                  record "now";
                  42)
            in
            Eta.Exit.Ok
              (Timer.refresh_node_on_demand
                 ~runtime_mismatch:(fun _runtime_contract _timer ->
                   record "mismatch";
                   "runtime")
                 ~current_snapshot:(fun _timer ->
                   Timer_policy.snapshot
                     ~state:(Timer_policy.inactive_state ~generation:0)
                     ~on_demand_refresh_token:current_token)
                 ~effective_state:(fun _timer -> effective_state)
                 ~remember:(fun _timer -> record "remember")
                 ~run_operation:(fun _timer ~now_ms operation ->
                   record
                     ("run:" ^ operation ^ ":" ^ string_of_int now_ms))
                 refresh_context node))
      in
      Alcotest.(check (result unit string))
        (name ^ " result") expected_result result;
      Alcotest.(check (list string))
        (name ^ " events") expected_events !events)
    cases

let test_refresh_node_demand_runtime_mismatch_short_circuits () =
  with_runtime_and_foreign_contract @@ fun runtime foreign_contract ->
  let changed_state = ref false in
  let started = ref false in
  let bad =
    make_node_demand_case "bad" ~current:(inactive 0)
      ~effective:(inactive 0)
  in
  let unreached =
    make_node_demand_case "unreached" ~current:(inactive 0)
      ~effective:(inactive 0)
  in
  let cases = [ bad; unreached ] in
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
  let effect =
    Eta.Effect.Expert.make
      ~leaf_name:"eta_signal.timer.test_node_runtime_mismatch" @@ fun context ->
    let runtime_contract = Eta.Effect.Expert.contract context in
    let make_node runtime_contract case =
      let node =
        Timer.create_node ~runtime_contract
          ~refresh_when_inactive:true ~refresh_operation:None
          ~start:
            (Timer.start ~run:(fun _timer ->
                 started := true;
                 Eta.Effect.unit))
      in
      case.case_node <- Some node;
      node
    in
    let bad_node = make_node foreign_contract bad in
    let unreached_node = make_node runtime_contract unreached in
    let plan =
      Timer.node_demand_plan
        ~timers:[ (1, bad_node); (2, unreached_node) ]
        ~is_necessary:(fun id -> id = 1)
        ~runtime_mismatch:(fun _runtime _timer -> "runtime")
        ~state:
          (Timer.state_port
             ~effective:(fun timer -> (find_case timer).case_effective)
             ~current:(fun timer -> (find_case timer).case_current)
             ~set_current:(fun _timer _state -> changed_state := true))
    in
    match
      Timer.refresh_node_demand_plan ~advance_generation:succ
        ~cancel_running:true plan runtime_contract
    with
    | Error "runtime" -> Eta.Exit.Ok ()
    | Error error -> Alcotest.failf "unexpected error %s" error
    | Ok _ -> Alcotest.fail "expected runtime validation failure"
  in
  run_ok runtime effect;
  Alcotest.(check bool) "no state changes" false !changed_state;
  Alcotest.(check bool) "no start effects" false !started;
  Alcotest.(check string) "bad state unchanged" "inactive:0"
    (state_label bad.case_current)

let test_mark_node_unneeded_marks_starting_inactive () =
  with_runtime @@ fun runtime ->
  let events = ref [] in
  let record event = append_event events event in
  let starting =
    make_node_demand_case "starting"
      ~current:(Timer_policy.starting_state ~generation:4)
      ~effective:(Timer_policy.starting_state ~generation:4)
  in
  let inactive_timer =
    make_node_demand_case "inactive" ~current:(inactive 9)
      ~effective:(inactive 9)
  in
  let cases = [ starting; inactive_timer ] in
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
  let starting_hooks, inactive_hooks =
    run_ok runtime
      (Eta.Effect.Expert.make
         ~leaf_name:"eta_signal.timer.test_mark_node_unneeded"
       @@ fun context ->
         let runtime_contract = Eta.Effect.Expert.contract context in
         let make_node case =
           let node =
             Timer.create_node ~runtime_contract
               ~refresh_when_inactive:true ~refresh_operation:None
               ~start:(Timer.start ~run:(fun _timer -> Eta.Effect.unit))
           in
           case.case_node <- Some node;
           node
         in
         let starting_node = make_node starting in
         let inactive_node = make_node inactive_timer in
         let port =
           Timer.state_port
             ~effective:(fun timer -> (find_case timer).case_effective)
             ~current:(fun timer -> (find_case timer).case_current)
             ~set_current:(fun timer state ->
               let case = find_case timer in
               case.case_current <- state;
               case.case_effective <- state;
               record ("set:" ^ case.case_name ^ ":" ^ state_label state))
         in
         let starting_hooks =
           Timer.mark_node_unneeded ~advance_generation:succ
             ~cancel_running:true port starting_node
         in
         let inactive_hooks =
           Timer.mark_node_unneeded ~advance_generation:succ
             ~cancel_running:true port inactive_node
         in
         Eta.Exit.Ok (starting_hooks, inactive_hooks))
  in
  Alcotest.(check (list string))
    "events" [ "set:starting:inactive:5" ] !events;
  Alcotest.(check int) "starting hooks" 0 (List.length starting_hooks);
  Alcotest.(check int) "inactive hooks" 0 (List.length inactive_hooks);
  Alcotest.(check string) "starting state" "inactive:5"
    (state_label starting.case_current);
  Alcotest.(check string) "inactive state" "inactive:9"
    (state_label inactive_timer.case_current)

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

let test_preflight_and_finish_node_own_state_port () =
  let events = ref [] in
  let record event = append_event events event in
  let checked_succ generation =
    if generation = max_int then
      invalid_arg "timer generation"
    else generation + 1
  in
  let running generation =
    Timer_policy.running_state ~generation ~next_due_ms:None
      ~cancel:(fun () -> record "cancel")
  in
  let starting =
    make_timer "starting" ~current:(inactive 0)
      ~effective:(Timer_policy.starting_state ~generation:0)
  in
  let finishing =
    make_timer "finishing" ~current:(running 3) ~effective:(running 3)
  in
  let overflowing =
    make_timer "overflow" ~current:(running max_int)
      ~effective:(running max_int)
  in
  let port = state_port ~record () in
  Timer.preflight_start ~advance_generation:checked_succ port starting;
  Alcotest.(check string)
    "start preflight does not mutate" "inactive:0"
    (state_label starting.current);
  Alcotest.check_raises "stop preflight overflows before mutation"
    (Invalid_argument "timer generation")
    (fun () ->
      Timer.preflight_stop ~advance_generation:checked_succ port overflowing);
  Alcotest.(check string)
    "overflow preflight does not mutate"
    ("running:" ^ string_of_int max_int)
    (state_label overflowing.current);
  Timer.finish_node ~advance_generation:checked_succ port finishing;
  Alcotest.(check string) "finished" "finished:4"
    (state_label finishing.current);
  Alcotest.(check (list string))
    "only finish mutates state" [ "set:finishing:finished:4" ] !events

let daemon_context events port update =
  Timer.daemon_context ~advance_generation:succ
    ~state_access:
      (Timer.daemon_state_access ~with_state:(fun f ->
           Eta.Effect.sync (fun () ->
               append_event events "access";
               f ())))
    ~state:port ~update
    ~hooks:
      (Timer.daemon_hooks
         ~after_due_read_before_commit:(fun () ->
           Eta.Effect.sync (fun () -> append_event events "due_hook"))
         ~after_update_constructed_before_run:(fun () ->
           Eta.Effect.sync (fun () -> append_event events "after_update")))

let test_start_daemon_wires_start_update_through_timer_port () =
  with_runtime @@ fun runtime ->
  let events = ref [] in
  let timer =
    make_timer "daemon"
      ~current:(Timer_policy.starting_state ~generation:3)
      ~effective:(Timer_policy.starting_state ~generation:3)
  in
  let port =
    Timer.state_port
      ~effective:(fun timer -> timer.effective)
      ~current:(fun timer -> timer.current)
      ~set_current:(fun timer state ->
        timer.current <- state;
        append_event events ("set:" ^ state_label state))
  in
  run_ok runtime
    (Timer.start_daemon
       (daemon_context events port
          (Timer.daemon_update ~update:(fun _timer ~generation ~missed ->
               Eta.Effect.sync (fun () ->
                   append_event events
                     ("update:" ^ string_of_int generation ^ ":"
                    ^ string_of_int missed)))))
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
    Timer.state_port
      ~effective:(fun _timer -> !effective)
      ~current:(fun _timer -> !current)
      ~set_current:(fun _timer state ->
        current := state;
        append_event events ("set:" ^ state_label state))
  in
  let effect =
    Eta.Effect.Expert.make ~leaf_name:"eta_signal.timer.test_node"
    @@ fun context ->
    let runtime_contract = Eta.Effect.Expert.contract context in
    let timer =
      Timer.create_daemon_node ~runtime_contract ~refresh_when_inactive:true
        ~refresh_operation:None
        (daemon_context events port
           (Timer.daemon_update ~update:(fun _timer ~generation ~missed ->
                Eta.Effect.sync (fun () ->
                    append_event events
                      ("update:" ^ string_of_int generation ^ ":"
                     ^ string_of_int missed)))))
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
          Alcotest.test_case "node helper owns start wiring" `Quick
            test_refresh_node_demand_owns_node_start_wiring;
          Alcotest.test_case "node refresh transaction owns bracketing" `Quick
            test_node_demand_refresh_owns_node_bracketing;
          Alcotest.test_case "node refresh demand order" `Quick
            test_refresh_node_on_demand_owns_validation_and_token_order;
          Alcotest.test_case "runtime mismatch short-circuits" `Quick
            test_refresh_node_demand_runtime_mismatch_short_circuits;
          Alcotest.test_case "marks unneeded node inactive" `Quick
            test_mark_node_unneeded_marks_starting_inactive;
          Alcotest.test_case "daemon lifecycle transitions" `Quick
            test_daemon_lifecycle_transitions;
          Alcotest.test_case "due lifecycle transitions" `Quick
            test_due_lifecycle_transitions;
          Alcotest.test_case "preflight and finish own state port" `Quick
            test_preflight_and_finish_node_own_state_port;
          Alcotest.test_case "start daemon callback ownership" `Quick
            test_start_daemon_wires_start_update_through_timer_port;
          Alcotest.test_case "daemon node start ownership" `Quick
            test_create_daemon_node_owns_start_effect_generation;
        ] );
    ]
