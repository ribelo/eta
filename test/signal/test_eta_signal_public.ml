module E = Eta.Effect

module Observer_error = struct
  type t = [ `Observer_failed ]

  let pp formatter = function
    | `Observer_failed -> Format.pp_print_string formatter "observer failed"
end

module Signal = Eta_signal.Make (Observer_error) ()

type test_error =
  [ Signal.graph_error
  | Signal.observer_read_error
  | Signal.stabilize_error
  | Signal.time_error
  | Signal.stream_error ]

let pp_hidden formatter _ = Format.pp_print_string formatter "<signal-error>"

let widen (eff : ('a, [< test_error ]) E.t) : ('a, test_error) E.t =
  E.map_error (fun error -> (error :> test_error)) eff

let run_ok runtime eff =
  Eta_test.Expect.expect_ok (Eta.Runtime.run runtime (widen eff))

let wait_until label predicate =
  let rec loop attempts =
    if predicate () then ()
    else if attempts = 0 then Alcotest.failf "timed out waiting for %s" label
    else (
      Eio.Fiber.yield ();
      loop (attempts - 1))
  in
  loop 200

let expect_fail label pred = function
  | Eta.Exit.Error (Eta.Cause.Fail error) when pred error -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s: expected typed failure, got %a" label
        (Eta.Cause.pp pp_hidden) cause
  | Eta.Exit.Ok _ -> Alcotest.failf "%s: expected typed failure, got Ok" label

let record updates update =
  E.sync (fun () -> updates := update :: !updates)

let test_basic_observe_stabilize_read () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = Signal.Var.create 1 in
  let doubled = Signal.Var.watch source |> Signal.map (fun value -> value * 2) in
  let updates = ref [] in
  let observer =
    run_ok runtime (Signal.Observer.observe doubled (record updates))
  in
  run_ok runtime Signal.stabilize;
  run_ok runtime (Signal.Var.set source 2);
  run_ok runtime Signal.stabilize;
  Alcotest.(check int) "current" 4
    (run_ok runtime (Signal.Observer.read observer));
  (match List.rev !updates with
   | [ Signal.Initialized 2; Signal.Changed { old_value = 2; new_value = 4 } ]
     ->
       ()
   | _ -> Alcotest.fail "unexpected observer updates");
  run_ok runtime (Signal.Observer.dispose observer)

let test_bind_switch_detaches_stale_dependency () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 10 in
  let right = Signal.Var.create 20 in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) (fun use_left ->
        if use_left then Signal.Var.watch left else Signal.Var.watch right)
  in
  let observer =
    run_ok runtime (Signal.Observer.observe selected (fun _ -> E.unit))
  in
  run_ok runtime Signal.stabilize;
  run_ok runtime (Signal.Var.set choose_left false);
  run_ok runtime Signal.stabilize;
  run_ok runtime (Signal.Var.set left 99);
  run_ok runtime Signal.stabilize;
  Alcotest.(check int) "right branch after left update" 20
    (run_ok runtime (Signal.Observer.read observer));
  run_ok runtime (Signal.Var.set right 21);
  run_ok runtime Signal.stabilize;
  Alcotest.(check int) "right branch update" 21
    (run_ok runtime (Signal.Observer.read observer));
  run_ok runtime (Signal.Observer.dispose observer)

let test_stream_bridge_emits_and_closes () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let observer, stream = run_ok runtime (Signal.Stream.observe signal) in
  run_ok runtime Signal.stabilize;
  let first =
    run_ok runtime (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
  in
  run_ok runtime (Signal.Var.set source 2);
  run_ok runtime Signal.stabilize;
  let second =
    run_ok runtime (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
  in
  run_ok runtime (Signal.Observer.dispose observer);
  let rest = run_ok runtime (Eta_stream.run_collect stream) in
  match (first, second, rest) with
  | ( [ Signal.Initialized 1 ],
      [ Signal.Changed { old_value = 1; new_value = 2 } ],
      [] ) ->
      ()
  | _ -> Alcotest.fail "unexpected stream updates"

let test_interval_catches_up_with_test_clock () =
  Eta_test.with_test_clock @@ fun _sw clock runtime ->
  let interval = run_ok runtime (Signal.Time.interval (Eta.Duration.ms 10)) in
  let observer =
    run_ok runtime (Signal.Observer.observe interval (fun _ -> E.unit))
  in
  run_ok runtime Signal.stabilize;
  Alcotest.(check int) "initial interval" 0
    (run_ok runtime (Signal.Observer.read observer));
  Eta_test.Test_clock.set_time clock 55;
  run_ok runtime Signal.stabilize;
  Alcotest.(check int) "caught up interval" 5
    (run_ok runtime (Signal.Observer.read observer));
  run_ok runtime (Signal.Observer.dispose observer)

let with_late_timer_wake ?(jump_ms = 1_000_000) f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let now_ms = ref 0 in
  let sleep_calls = ref 0 in
  let hold, hold_resolver = Eio.Promise.create () in
  let released = ref false in
  let sleep _duration =
    incr sleep_calls;
    if !sleep_calls = 1 then now_ms := jump_ms
    else Eio.Promise.await hold
  in
  let release () =
    if not !released then (
      released := true;
      Eio.Promise.resolve hold_resolver ())
  in
  let runtime =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ~sleep
      ~now_ms:(fun () -> !now_ms)
      ()
  in
  Fun.protect ~finally:release (fun () -> f runtime sleep_calls)

let test_step_coalesced_bounds_large_late_wake () =
  with_late_timer_wake @@ fun runtime sleep_calls ->
  let applied = ref 0 in
  let missed_seen = ref None in
  let step =
    run_ok runtime
      (Signal.Time.step_coalesced ~every:(Eta.Duration.ms 1) ~initial:0
         (fun ~missed value ->
           incr applied;
           missed_seen := Some missed;
           value + missed))
  in
  let observer =
    run_ok runtime (Signal.Observer.observe step (fun _ -> E.unit))
  in
  wait_until "coalesced step late wake" (fun () -> !sleep_calls >= 2);
  Alcotest.(check int) "coalesced update calls" 1 !applied;
  Alcotest.(check (option int))
    "coalesced missed count" (Some 1_000_000) !missed_seen;
  run_ok runtime Signal.stabilize;
  Alcotest.(check int) "coalesced step value" 1_000_000
    (run_ok runtime (Signal.Observer.read observer));
  run_ok runtime (Signal.Observer.dispose observer)

let test_timer_runtime_mismatch_on_observe () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock_a = Eta_test.Test_clock.create () in
  let clock_b = Eta_test.Test_clock.create () in
  let rt_a =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock_a)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock_a)
      ()
  in
  let rt_b =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock_b)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock_b)
      ()
  in
  let timer = run_ok rt_a (S.Time.interval (Eta.Duration.ms 10)) in
  expect_fail "observe timer from another runtime"
    (function `Runtime_mismatch -> true | _ -> false)
    (Eta.Runtime.run rt_b (widen (S.Observer.observe timer (fun _ -> E.unit))));
  let keep_alive =
    run_ok rt_a (S.Observer.observe timer (fun _ -> E.unit))
  in
  Fun.protect
    ~finally:(fun () -> run_ok rt_a (S.Observer.dispose keep_alive))
    (fun () ->
      run_ok rt_a S.stabilize;
      expect_fail "observe active timer from another runtime"
        (function `Runtime_mismatch -> true | _ -> false)
        (Eta.Runtime.run rt_b
           (widen (S.Observer.observe timer (fun _ -> E.unit)))))

let test_captured_branch_observer_invalidates_without_owner_observer () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let choose_left = S.Var.create true in
  let left = S.Var.create 10 in
  let right = S.Var.create 20 in
  let captured_left = ref None in
  let selected =
    S.bind (S.Var.watch choose_left) (fun use_left ->
        if use_left then (
          let branch = S.Var.watch left in
          captured_left := Some branch;
          branch)
        else S.Var.watch right)
  in
  let selected_observer =
    run_ok runtime (S.Observer.observe selected (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  let branch =
    match !captured_left with
    | Some branch -> branch
    | None -> Alcotest.fail "expected captured branch"
  in
  run_ok runtime (S.Observer.dispose selected_observer);
  let branch_observer =
    run_ok runtime (S.Observer.observe branch (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  Alcotest.(check int) "branch initialized" 10
    (run_ok runtime (S.Observer.read branch_observer));
  run_ok runtime (S.Var.set choose_left false);
  run_ok runtime S.stabilize;
  expect_fail "captured branch read after switch" (( = ) `Invalid_scope)
    (Eta.Runtime.run runtime (widen (S.Observer.read branch_observer)));
  run_ok runtime (S.Observer.dispose branch_observer)

let test_observer_failure_retries_pending_delivery () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 0 in
  let updates = ref [] in
  let fail_next_change = ref false in
  let observer =
    run_ok runtime
      (S.Observer.observe (S.Var.watch source) (fun update ->
           match update with
           | S.Initialized _ -> record updates update
           | S.Changed _ when !fail_next_change ->
               fail_next_change := false;
               E.fail `Observer_failed
           | S.Changed _ -> record updates update))
  in
  run_ok runtime S.stabilize;
  fail_next_change := true;
  run_ok runtime (S.Var.set source 1);
  expect_fail "observer failure"
    (function `Observer_error `Observer_failed -> true | _ -> false)
    (Eta.Runtime.run runtime (widen S.stabilize));
  Alcotest.(check int) "snapshot committed despite callback failure" 1
    (run_ok runtime (S.Observer.read observer));
  run_ok runtime S.stabilize;
  (match List.rev !updates with
   | [ S.Initialized 0; S.Changed { old_value = 0; new_value = 1 } ] -> ()
   | _ -> Alcotest.fail "expected pending delivery to retry");
  run_ok runtime (S.Observer.dispose observer)

let test_stream_overflow_does_not_block_graph_progress () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 0 in
  let signal = S.Var.watch source in
  let stream_observer, stream =
    run_ok runtime (S.Stream.observe ~capacity:1 signal)
  in
  let observer_updates = ref [] in
  let ordinary_observer =
    run_ok runtime (S.Observer.observe signal (record observer_updates))
  in
  run_ok runtime S.stabilize;
  let before_drop = run_ok runtime (S.stats ()) in
  run_ok runtime (S.Var.set source 1);
  run_ok runtime S.stabilize;
  let after_drop = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "ordinary observer progressed" 2
    (List.length !observer_updates);
  Alcotest.(check int) "full bridge dropped one update"
    (before_drop.S.stream_bridge_drop_count + 1)
    after_drop.S.stream_bridge_drop_count;
  run_ok runtime (S.Var.set source 2);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "ordinary observer still progresses" 3
    (List.length !observer_updates);
  (match
     run_ok runtime (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ S.Initialized 0 ] -> ()
   | _ -> Alcotest.fail "expected buffered initialized stream update");
  run_ok runtime (S.Observer.dispose ordinary_observer);
  run_ok runtime (S.Observer.dispose stream_observer)

let () =
  Alcotest.run "eta_signal_public"
    [
      ( "public",
        [
          Alcotest.test_case "observe stabilize read" `Quick
            test_basic_observe_stabilize_read;
          Alcotest.test_case "bind switch detaches stale dependency" `Quick
            test_bind_switch_detaches_stale_dependency;
          Alcotest.test_case "stream bridge emits and closes" `Quick
            test_stream_bridge_emits_and_closes;
          Alcotest.test_case "interval catches up with test clock" `Quick
            test_interval_catches_up_with_test_clock;
          Alcotest.test_case "step_coalesced bounds large late wake" `Quick
            test_step_coalesced_bounds_large_late_wake;
          Alcotest.test_case "timer runtime mismatch on observe" `Quick
            test_timer_runtime_mismatch_on_observe;
          Alcotest.test_case "captured branch observer invalidates" `Quick
            test_captured_branch_observer_invalidates_without_owner_observer;
          Alcotest.test_case "observer failure retries pending delivery" `Quick
            test_observer_failure_retries_pending_delivery;
          Alcotest.test_case "stream overflow does not block graph progress"
            `Quick test_stream_overflow_does_not_block_graph_progress;
        ] );
    ]
