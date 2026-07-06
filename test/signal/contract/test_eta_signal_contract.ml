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

let render pp value = Format.asprintf "%a" pp value

let check_render label pp value expected =
  Alcotest.(check string) label expected (render pp value)

let record updates update =
  E.sync (fun () -> updates := update :: !updates)

let count_occurrences text needle =
  let text_len = String.length text in
  let needle_len = String.length needle in
  let rec loop index count =
    if needle_len = 0 || index + needle_len > text_len then count
    else if String.sub text index needle_len = needle then
      loop (index + needle_len) (count + 1)
    else loop (index + 1) count
  in
  loop 0 0

let wait_until label predicate =
  let rec loop attempts =
    if predicate () then ()
    else if attempts = 0 then Alcotest.failf "timed out waiting for %s" label
    else (
      Eio.Fiber.yield ();
      loop (attempts - 1))
  in
  loop 200

let test_error_pretty_printers_are_clear () =
  let module S = Eta_signal.Make (Observer_error) () in
  check_render "ambiguous scope" S.pp_graph_error `Ambiguous_scope
    "ambiguous dynamic scope";
  check_render "cycle" S.pp_graph_error `Cycle "cycle detected";
  check_render "invalid scope" S.pp_graph_error `Invalid_scope
    "invalid dynamic scope";
  check_render "reentrant stabilization" S.pp_graph_error
    `Reentrant_stabilization "reentrant stabilization";
  check_render "reentrant update" S.pp_graph_error `Reentrant_update
    "same-variable effectful update reentry";
  check_render "disposed observer" S.pp_observer_read_error
    `Disposed_observer "disposed observer";
  check_render "invalid observer scope" S.pp_observer_read_error
    `Invalid_scope "invalid dynamic scope";
  check_render "no current observer value" S.pp_observer_read_error
    `No_current_value "no current observer value";
  check_render "uninitialized observer" S.pp_observer_read_error
    `Uninitialized_observer "uninitialized observer";
  check_render "stabilize graph error" S.pp_stabilize_error
    `Reentrant_stabilization "reentrant stabilization";
  check_render "stabilize observer error" S.pp_stabilize_error
    (`Observer_error `Observer_failed) "observer callback failed: observer failed";
  check_render "deadline overflow" S.pp_time_error `Deadline_overflow
    "deadline arithmetic overflow";
  check_render "invalid interval" S.pp_time_error `Invalid_interval
    "invalid interval";
  check_render "past deadline" S.pp_time_error `Past_deadline
    "deadline is in the past";
  check_render "stream graph error" S.pp_stream_error `Cycle
    "cycle detected";
  check_render "invalid stream capacity" S.pp_stream_error
    `Invalid_capacity "stream bridge capacity must be positive"

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

let test_observer_read_does_not_force_recompute () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let recomputes = ref 0 in
  let signal =
    S.Var.watch source
    |> S.map (fun value ->
           incr recomputes;
           value)
  in
  let observer = run_ok runtime (S.Observer.observe signal (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  let after_stabilize = run_ok runtime (S.stats ()) in
  run_ok runtime (S.Var.set source 2);
  let before_read = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "read returns old stabilized snapshot" 1
    (run_ok runtime (S.Observer.read observer));
  let after_read = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "observer read does not stabilize"
    before_read.S.pure_snapshot_commit_count
    after_read.S.pure_snapshot_commit_count;
  Alcotest.(check int) "observer read does not recompute"
    before_read.S.recompute_count after_read.S.recompute_count;
  Alcotest.(check int) "pending update was not recomputed by read" 1
    !recomputes;
  run_ok runtime S.stabilize;
  let after_second_stabilize = run_ok runtime (S.stats ()) in
  Alcotest.(check bool) "later stabilization recomputes" true
    (after_second_stabilize.S.recompute_count > after_read.S.recompute_count);
  Alcotest.(check int) "map recomputed by later stabilization" 2 !recomputes;
  Alcotest.(check bool) "stabilization count advanced" true
    (after_second_stabilize.S.pure_snapshot_commit_count
     > after_stabilize.S.pure_snapshot_commit_count);
  Alcotest.(check int) "observer sees new snapshot after stabilize" 2
    (run_ok runtime (S.Observer.read observer));
  run_ok runtime (S.Observer.dispose observer)

let test_diagnostics_track_observation_and_disposal () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  run_ok runtime S.stabilize;
  let before = run_ok runtime (S.stats ()) in
  let before_dot_nodes =
    count_occurrences (run_ok runtime (S.to_dot ())) "[label="
  in
  let source = S.Var.create 1 in
  run_ok runtime (S.Var.set source 2);
  let signal = S.Var.watch source |> S.map (fun value -> value + 1) in
  let observer =
    run_ok runtime (S.Observer.observe signal (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  let after_observe = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "observer after prior stabilization sees latest source"
    3
    (run_ok runtime (S.Observer.read observer));
  Alcotest.(check bool) "observe after stabilization adds demand" true
    (after_observe.S.necessary_node_count > before.S.necessary_node_count);
  Alcotest.(check bool) "to_dot shows observed graph" true
    (count_occurrences (run_ok runtime (S.to_dot ())) "[label="
     > before_dot_nodes);
  run_ok runtime (S.Observer.dispose observer);
  run_ok runtime S.stabilize;
  let after_dispose = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "disposal returns active observer count to baseline"
    before.S.active_observer_count after_dispose.S.active_observer_count;
  Alcotest.(check bool) "disposal releases necessary graph" true
    (after_dispose.S.necessary_node_count <= before.S.necessary_node_count);
  Alcotest.(check bool) "to_dot returns to baseline necessary graph" true
    (count_occurrences (run_ok runtime (S.to_dot ())) "[label="
     <= before_dot_nodes)

let test_default_cutoff_is_physical_equality () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let initial = Array.make 1 1 in
  let next = Array.copy initial in
  Alcotest.(check bool) "test values are distinct blocks" false
    (initial == next);
  let source = S.Var.create initial in
  let events = ref [] in
  let observer =
    run_ok runtime (S.Observer.observe (S.Var.watch source) (record events))
  in
  run_ok runtime S.stabilize;
  run_ok runtime (S.Var.set source next);
  run_ok runtime S.stabilize;
  (match List.rev !events with
   | [ S.Initialized initialized; S.Changed { old_value; new_value } ] ->
       Alcotest.(check (list int)) "initialized value" [ 1 ]
         (Array.to_list initialized);
       Alcotest.(check bool) "old value is initial block" true
         (old_value == initial);
       Alcotest.(check bool) "new value is next block" true
         (new_value == next)
   | _ -> Alcotest.fail "expected initialized and changed events");
  Alcotest.(check bool) "observer current is next block" true
    (run_ok runtime (S.Observer.read observer) == next);
  run_ok runtime (S.Observer.dispose observer)

let test_default_physical_cutoff_suppresses_in_place_mutation () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let block = Array.make 1 1 in
  let source = S.Var.create block in
  let mapped_calls = ref 0 in
  let mapped =
    S.Var.watch source
    |> S.map (fun value ->
           incr mapped_calls;
           Array.get value 0)
  in
  let events = ref [] in
  let callbacks = ref 0 in
  let observer =
    run_ok runtime
      (S.Observer.observe mapped (fun update ->
           E.sync (fun () ->
               incr callbacks;
               events := update :: !events)))
  in
  run_ok runtime S.stabilize;
  Alcotest.(check int) "initial callback delivered" 1 !callbacks;
  Alcotest.(check int) "initial mapped value" 1
    (run_ok runtime (S.Observer.read observer));
  Array.set block 0 2;
  run_ok runtime (S.Var.set source block);
  Alcotest.(check int) "direct source exposes mutated block" 2
    (Array.get (S.Var.value source) 0);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "physical cutoff suppresses recompute" 1
    !mapped_calls;
  Alcotest.(check int) "same-block mutation emits no second callback" 1
    !callbacks;
  Alcotest.(check int) "observer keeps previous derived snapshot" 1
    (run_ok runtime (S.Observer.read observer));
  (match List.rev !events with
   | [ S.Initialized 1 ] -> ()
   | _ -> Alcotest.fail "expected no event after same-block mutation");
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
          Alcotest.test_case "error pretty printers are clear" `Quick
            test_error_pretty_printers_are_clear;
          Alcotest.test_case "explicit stabilization boundary" `Quick
            test_explicit_stabilization_boundary;
          Alcotest.test_case "observer read does not force recompute" `Quick
            test_observer_read_does_not_force_recompute;
          Alcotest.test_case "diagnostics track observation and disposal"
            `Quick test_diagnostics_track_observation_and_disposal;
          Alcotest.test_case "default cutoff is physical equality" `Quick
            test_default_cutoff_is_physical_equality;
          Alcotest.test_case "physical cutoff suppresses in-place mutation"
            `Quick test_default_physical_cutoff_suppresses_in_place_mutation;
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
