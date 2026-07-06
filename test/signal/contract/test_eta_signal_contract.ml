module E = Eta.Effect

module Observer_error = struct
  type t = [ `Observer_failed ]

  let pp ppf = function
    | `Observer_failed -> Format.pp_print_string ppf "observer failed"
end

module Signal = Eta_signal.Make (Observer_error) ()

type test_error =
  [ Signal.graph_error
  | Signal.observer_read_error
  | Signal.stabilize_error
  | Signal.time_error
  | Signal.stream_error ]

let pp_hidden ppf _ = Format.pp_print_string ppf "<signal-error>"

let widen (eff : ('a, [< test_error ]) E.t) : ('a, test_error) E.t =
  E.map_error (fun error -> (error :> test_error)) eff

let run runtime eff = Eta.Runtime.run runtime (widen eff)

let run_ok runtime eff =
  match run runtime eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected Ok, got %a" (Eta.Cause.pp pp_hidden) cause

let expect_fail label pred = function
  | Eta.Exit.Error (Eta.Cause.Fail err) when pred err -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s: expected typed failure, got %a" label
        (Eta.Cause.pp pp_hidden) cause
  | Eta.Exit.Ok _ -> Alcotest.failf "%s: expected typed failure, got Ok" label

let expect_die label = function
  | Eta.Exit.Error (Eta.Cause.Die _) -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s: expected defect, got %a" label
        (Eta.Cause.pp pp_hidden) cause
  | Eta.Exit.Ok _ -> Alcotest.failf "%s: expected defect, got Ok" label

let record updates update =
  E.sync (fun () -> updates := update :: !updates)

let wait_until label predicate =
  let rec loop attempts =
    if predicate () then ()
    else if attempts = 0 then Alcotest.failf "timed out waiting for %s" label
    else (
      Eio.Fiber.yield ();
      loop (attempts - 1))
  in
  loop 200

let test_explicit_stabilization_boundary () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let derived = S.Var.watch source |> S.map (fun value -> value * 10) in
  let updates = ref [] in
  let observer = run_ok runtime (S.Observer.observe derived (record updates)) in
  expect_fail "read before first stabilization" (( = ) `Uninitialized_observer)
    (run runtime (S.Observer.read observer));
  run_ok runtime (S.Var.set source 2);
  Alcotest.(check int) "set does not deliver callbacks" 0 (List.length !updates);
  expect_fail "set does not initialize observer" (( = ) `Uninitialized_observer)
    (run runtime (S.Observer.read observer));
  run_ok runtime S.stabilize;
  Alcotest.(check int) "first stabilized value" 20
    (run_ok runtime (S.Observer.read observer));
  run_ok runtime (S.Var.set source 3);
  Alcotest.(check int) "read stays on committed snapshot" 20
    (run_ok runtime (S.Observer.read observer));
  Alcotest.(check int) "second set still has no callback" 1 (List.length !updates);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "second stabilized value" 30
    (run_ok runtime (S.Observer.read observer));
  (match List.rev !updates with
   | [ S.Initialized 20; S.Changed { old_value = 20; new_value = 30 } ] -> ()
   | _ -> Alcotest.fail "unexpected explicit stabilization updates");
  run_ok runtime (S.Observer.dispose observer)

let test_pure_failure_preserves_snapshot_and_retries () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let signal =
    S.Var.watch source
    |> S.map (fun value ->
           if value = 2 then failwith "contract pure failure";
           value)
  in
  let observer = run_ok runtime (S.Observer.observe signal (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  run_ok runtime (S.Var.set source 2);
  expect_die "pure failure" (run runtime S.stabilize);
  Alcotest.(check int) "old snapshot remains after pure failure" 1
    (run_ok runtime (S.Observer.read observer));
  run_ok runtime (S.Var.set source 3);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "later stabilization retries from pending graph" 3
    (run_ok runtime (S.Observer.read observer));
  run_ok runtime (S.Observer.dispose observer)

let test_observer_phase_mutation_is_delayed () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let signal = S.Var.watch source in
  let updates = ref [] in
  let observer =
    run_ok runtime
      (S.Observer.observe signal (fun update ->
           record updates update
           |> E.bind (fun () ->
                  match update with
                  | S.Initialized 1 ->
                      S.Var.set source 2
                      |> E.map_error (fun _ -> `Observer_failed)
                  | Initialized _ | Changed _ -> E.unit)))
  in
  run_ok runtime S.stabilize;
  Alcotest.(check int) "observer-phase read uses committed snapshot" 1
    (run_ok runtime (S.Observer.read observer));
  run_ok runtime S.stabilize;
  Alcotest.(check int) "observer mutation publishes next stabilization" 2
    (run_ok runtime (S.Observer.read observer));
  (match List.rev !updates with
   | [ S.Initialized 1; S.Changed { old_value = 1; new_value = 2 } ] -> ()
   | _ -> Alcotest.fail "unexpected observer-phase updates");
  run_ok runtime (S.Observer.dispose observer)

let test_observer_failure_commits_snapshot_and_retries_delivery () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 0 in
  let delivered = ref [] in
  let fail_next_change = ref false in
  let observer =
    run_ok runtime
      (S.Observer.observe (S.Var.watch source) (fun update ->
           match update with
           | S.Initialized _ -> record delivered update
           | S.Changed _ when !fail_next_change ->
               fail_next_change := false;
               E.fail `Observer_failed
           | S.Changed _ -> record delivered update))
  in
  run_ok runtime S.stabilize;
  fail_next_change := true;
  run_ok runtime (S.Var.set source 1);
  expect_fail "observer failure"
    (function `Observer_error `Observer_failed -> true | _ -> false)
    (run runtime S.stabilize);
  Alcotest.(check int) "snapshot committed despite observer failure" 1
    (run_ok runtime (S.Observer.read observer));
  run_ok runtime S.stabilize;
  (match List.rev !delivered with
   | [ S.Initialized 0; S.Changed { old_value = 0; new_value = 1 } ] -> ()
   | _ -> Alcotest.fail "expected failed delivery to retry");
  run_ok runtime (S.Observer.dispose observer)

let test_demand_boundary_for_derived_nodes_and_timers () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock runtime ->
  let source = S.Var.create 0 in
  let recomputes = ref 0 in
  let derived =
    S.Var.watch source
    |> S.map (fun value ->
           incr recomputes;
           value + 1)
  in
  run_ok runtime (S.Var.set source 1);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "unobserved derived node did not recompute" 0
    !recomputes;
  let derived_observer =
    run_ok runtime (S.Observer.observe derived (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  Alcotest.(check int) "observed derived node recomputed" 1 !recomputes;
  let timer = run_ok runtime (S.Time.interval (Eta.Duration.ms 10)) in
  Eio.Fiber.yield ();
  Alcotest.(check int) "constructing timer does not start sleeper" 0
    (Eta_test.Test_clock.sleeper_count clock);
  let timer_observer =
    run_ok runtime (S.Observer.observe timer (fun _ -> E.unit))
  in
  wait_until "timer sleeper" (fun () ->
      Eta_test.Test_clock.sleeper_count clock >= 1);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "observed timer initializes at zero" 0
    (run_ok runtime (S.Observer.read timer_observer));
  run_ok runtime (S.Observer.dispose timer_observer);
  run_ok runtime (S.Observer.dispose derived_observer)

let test_stream_bridge_is_observer_plus_queue () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let signal = S.Var.watch source in
  let observer, stream =
    run_ok runtime (S.Stream.observe ~capacity:1 signal)
  in
  run_ok runtime S.stabilize;
  let first =
    run_ok runtime (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
  in
  run_ok runtime (S.Var.set source 2);
  run_ok runtime S.stabilize;
  let second =
    run_ok runtime (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
  in
  run_ok runtime (S.Observer.dispose observer);
  let rest = run_ok runtime (Eta_stream.run_collect stream) in
  match (first, second, rest) with
  | ( [ S.Initialized 1 ],
      [ S.Changed { old_value = 1; new_value = 2 } ],
      [] ) ->
      ()
  | _ -> Alcotest.fail "unexpected stream bridge queue behavior"

let test_stream_with_observed_disposes_on_exit () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let signal = S.Var.watch source in
  let leaked_stream = ref None in
  let stream_error eff = E.map_error (fun error -> (error :> test_error)) eff in
  let before_scope = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "starts without active observers" 0
    before_scope.S.active_observer_count;
  run_ok runtime
    (S.Stream.with_observed ~capacity:4 signal (fun stream ->
         leaked_stream := Some stream;
         E.unit));
  let after_scope = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "scoped stream observer disposed" 0
    after_scope.S.active_observer_count;
  let stream =
    match !leaked_stream with
    | Some stream -> stream
    | None -> Alcotest.fail "expected stream to be passed to consumer"
  in
  Alcotest.(check (list int))
    "scoped stream closes after consumer returns"
    []
    (List.map
       (function
         | S.Initialized value -> value
         | S.Changed { new_value; _ } -> new_value)
       (run_ok runtime (Eta_stream.run_collect stream |> stream_error)));
  run_ok runtime (S.Var.set source 2);
  run_ok runtime S.stabilize;
  let after_later_stabilize = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "scoped stream stays disposed" 0
    after_later_stabilize.S.active_observer_count;
  let manual_observer, _manual_stream =
    run_ok runtime
      (S.Stream.observe ~capacity:4 signal)
  in
  run_ok runtime S.stabilize;
  Alcotest.(check int) "manual stream can still be observed" 2
    (run_ok runtime (S.Observer.read manual_observer));
  run_ok runtime (S.Observer.dispose manual_observer)

let test_stream_bridge_full_queue_drops_newest () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let signal = S.Var.watch source in
  let drops = ref [] in
  let observer, stream =
    run_ok runtime
      (S.Stream.observe ~capacity:1
         ~on_drop:(fun update ->
           drops := update :: !drops;
           failwith "contract drop hook failure")
         signal)
  in
  run_ok runtime S.stabilize;
  let before_drop = run_ok runtime (S.stats ()) in
  run_ok runtime (S.Var.set source 2);
  run_ok runtime S.stabilize;
  let after_drop = run_ok runtime (S.stats ()) in
  Alcotest.(check int)
    "drop counted after acknowledgement"
    (before_drop.S.stream_bridge_drop_count + 1)
    after_drop.S.stream_bridge_drop_count;
  Alcotest.(check int)
    "observer snapshot still commits"
    2
    (run_ok runtime (S.Observer.read observer));
  (match !drops with
   | [ S.Changed { old_value = 1; new_value = 2 } ] -> ()
   | _ -> Alcotest.fail "expected newest stream update to be dropped");
  let update_value = function
    | S.Initialized value -> value
    | S.Changed { new_value; _ } -> new_value
  in
  Alcotest.(check (list int))
    "full queue keeps original item"
    [ 1 ]
    (List.map update_value
       (run_ok runtime
          (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)));
  run_ok runtime (S.Observer.dispose observer);
  Alcotest.(check (list int))
    "disposed bridge closes after buffered items"
    []
    (List.map update_value
       (run_ok runtime (Eta_stream.run_collect stream)))

let () =
  Alcotest.run "eta_signal_contract"
    [
      ( "contract",
        [
          Alcotest.test_case "explicit stabilization boundary" `Quick
            test_explicit_stabilization_boundary;
          Alcotest.test_case "pure failure preserves snapshot and retries"
            `Quick test_pure_failure_preserves_snapshot_and_retries;
          Alcotest.test_case "observer phase mutation is delayed" `Quick
            test_observer_phase_mutation_is_delayed;
          Alcotest.test_case
            "observer failure commits snapshot and retries delivery" `Quick
            test_observer_failure_commits_snapshot_and_retries_delivery;
          Alcotest.test_case "demand boundary for derived nodes and timers"
            `Quick test_demand_boundary_for_derived_nodes_and_timers;
          Alcotest.test_case "stream bridge is observer plus queue" `Quick
            test_stream_bridge_is_observer_plus_queue;
          Alcotest.test_case "stream scoped observation disposes observer"
            `Quick test_stream_with_observed_disposes_on_exit;
          Alcotest.test_case "stream bridge full queue drops newest" `Quick
            test_stream_bridge_full_queue_drops_newest;
        ] );
    ]
