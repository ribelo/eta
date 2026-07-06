let () =
  match Sys.getenv_opt "EIO_BACKEND" with
  | None | Some "" ->
      (Unix.putenv [@alert "-unsafe_multidomain"]) "EIO_BACKEND" "posix"
  | Some _ -> ()

open Eta

module Observer_error = struct
  type t = [ `Observer_failed ]

  let pp ppf = function
    | `Observer_failed -> Format.pp_print_string ppf "observer failed"
end

module Test_signal = Eta_signal_overflow_harness.Make (Observer_error) ()

type test_error =
  [ Test_signal.graph_error
  | Test_signal.observer_read_error
  | Test_signal.stabilize_error
  | Test_signal.time_error ]

let pp_hidden ppf _ = Format.pp_print_string ppf "<signal-error>"

let widen (eff : ('a, [< test_error ]) Effect.t) : ('a, test_error) Effect.t =
  Effect.map_error (fun err -> (err :> test_error)) eff

let run_ok rt eff =
  match Eta_eio.Runtime.run rt (widen eff) with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause

let expect_fail :
    type a. string -> (test_error -> bool) -> (a, test_error) Exit.t -> unit =
 fun label pred -> function
  | Exit.Error (Cause.Fail err) when pred err -> ()
  | Exit.Error cause ->
      Alcotest.failf "%s: expected typed failure, got %a" label
        (Cause.pp pp_hidden) cause
  | Exit.Ok _ -> Alcotest.failf "%s: expected typed failure, got Ok" label

let counter_overflow name = function
  | `Counter_overflow actual -> String.equal actual name
  | _ -> false

let rec cause_has_fail pred = function
  | Cause.Fail err -> pred err
  | Cause.Suppressed { primary; _ } -> cause_has_fail pred primary
  | Cause.Sequential causes | Cause.Concurrent causes ->
      List.exists (cause_has_fail pred) causes
  | Cause.Die _ | Cause.Interrupt _ | Cause.Finalizer _ -> false

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec matches_at haystack_index needle_index =
    needle_index = needle_len
    || (haystack_index + needle_index < haystack_len
       && Char.equal haystack.[haystack_index + needle_index]
            needle.[needle_index]
       && matches_at haystack_index (needle_index + 1))
  in
  let rec search index =
    needle_len = 0
    || (index + needle_len <= haystack_len
       && (matches_at index 0 || search (index + 1)))
  in
  search 0

let rec finalizer_has_die_message expected = function
  | Cause.Finalizer.Die die ->
      contains_substring (Printexc.to_string die.exn) expected
  | Cause.Finalizer.Fail _ | Cause.Finalizer.Interrupt _ -> false
  | Cause.Finalizer.Sequential causes | Cause.Finalizer.Concurrent causes ->
      List.exists (finalizer_has_die_message expected) causes
  | Cause.Finalizer.Finalizer cause -> finalizer_has_die_message expected cause
  | Cause.Finalizer.Suppressed { primary; finalizer } ->
      finalizer_has_die_message expected primary
      || finalizer_has_die_message expected finalizer

let rec cause_has_finalizer_die_message expected = function
  | Cause.Finalizer finalizer -> finalizer_has_die_message expected finalizer
  | Cause.Suppressed { primary; finalizer } ->
      cause_has_finalizer_die_message expected primary
      || finalizer_has_die_message expected finalizer
  | Cause.Sequential causes | Cause.Concurrent causes ->
      List.exists (cause_has_finalizer_die_message expected) causes
  | Cause.Fail _ | Cause.Die _ | Cause.Interrupt _ -> false

let expect_fail_with_finalizer_die label pred expected = function
  | Exit.Error cause
    when cause_has_fail pred cause
         && cause_has_finalizer_die_message expected cause ->
      ()
  | Exit.Error cause ->
      Alcotest.failf "%s: expected typed failure with finalizer defect %S, got %a"
        label expected (Cause.pp pp_hidden) cause
  | Exit.Ok _ ->
      Alcotest.failf "%s: expected typed failure with finalizer defect, got Ok"
        label

let with_runtime f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
      ()
  in
  f rt

let wait_for_sleepers clock expected =
  let rec loop attempts =
    if Eta_test.Test_clock.sleeper_count clock >= expected then ()
    else if attempts = 0 then
      Alcotest.failf "expected %d sleepers, got %d" expected
        (Eta_test.Test_clock.sleeper_count clock)
    else (
      Eta_test.Async.yield ();
      loop (attempts - 1))
  in
  loop 20

let test_signal_version_overflow_does_not_publish_partial_snapshot () =
  let module Test_signal = Eta_signal_overflow_harness.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let source = Test_signal.Var.create 1 in
  let signal = Test_signal.Var.watch source in
  let events = ref [] in
  let observer =
    run_ok rt
      (Test_signal.Observer.observe signal (fun update ->
           Effect.sync (fun () -> events := update :: !events)))
  in
  run_ok rt Test_signal.stabilize;
  Test_signal.Overflow.set_signal_version signal max_int;
  run_ok rt (Test_signal.Var.set source 2);
  expect_fail "signal version overflow" (counter_overflow "signal version")
    (Eta_eio.Runtime.run rt (widen Test_signal.stabilize));
  Alcotest.(check int) "old snapshot remains after version overflow" 1
    (run_ok rt (Test_signal.Observer.read observer));
  Test_signal.Overflow.set_signal_version signal 0;
  run_ok rt Test_signal.stabilize;
  Alcotest.(check int) "retry publishes pending source" 2
    (run_ok rt (Test_signal.Observer.read observer));
  (match List.rev !events with
  | [ Test_signal.Initialized 1;
      Changed { old_value = 1; new_value = 2 } ] ->
      ()
  | _ -> Alcotest.fail "expected retry to deliver changed event");
  run_ok rt (Test_signal.Observer.dispose observer)

let test_var_create_counter_overflow_raises_graph_error () =
  let module Test_signal = Eta_signal_overflow_harness.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  run_ok rt (Test_signal.Overflow.set_next_node_id max_int);
  match Test_signal.Var.create 1 with
  | exception Test_signal.Graph_error (`Counter_overflow name)
    when String.equal name "node id" ->
      ()
  | exception Test_signal.Graph_error _ ->
      Alcotest.fail "var create counter overflow: unexpected graph error"
  | exception exn ->
      Alcotest.failf "var create counter overflow: unexpected exception %s"
        (Printexc.to_string exn)
  | _ -> Alcotest.fail "var create counter overflow: expected graph error"

let test_stabilization_generation_overflow_is_typed_failure () =
  let module Test_signal = Eta_signal_overflow_harness.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  run_ok rt (Test_signal.Overflow.set_generation max_int);
  expect_fail "stabilization generation overflow"
    (counter_overflow "stabilization generation")
    (Eta_eio.Runtime.run rt (widen Test_signal.stabilize))

let test_timer_refresh_token_overflow_is_typed_failure () =
  let module Test_signal = Eta_signal_overflow_harness.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  run_ok rt (Test_signal.Overflow.set_next_timer_refresh_token max_int);
  expect_fail "timer refresh token overflow"
    (counter_overflow "timer refresh token")
    (Eta_eio.Runtime.run rt (widen Test_signal.stabilize))

let test_stats_counter_saturation_is_typed_failure () =
  let module Test_signal = Eta_signal_overflow_harness.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let check_stats_counter name =
    match Test_signal.Overflow.stats_counter ~name max_int with
    | Error (`Counter_overflow actual) ->
        Alcotest.(check string) (name ^ " pure saturation") name actual
    | Ok _ -> Alcotest.failf "%s: expected pure counter overflow" name
  in
  let check name counter =
    run_ok rt (Test_signal.Overflow.set_stats_counter counter max_int);
    expect_fail (name ^ " saturation") (counter_overflow name)
      (Eta_eio.Runtime.run rt (widen (Test_signal.stats ())));
    run_ok rt (Test_signal.Overflow.set_stats_counter counter 0)
  in
  List.iter check_stats_counter
    [
      "stats total_node_count";
      "stats necessary_node_count";
      "stats dead_node_count";
      "stats lane_cancelled_waiter_count";
    ];
  check "stats pure_snapshot_commit_count"
    Test_signal.Overflow.Pure_snapshot_commit_count;
  check "stats callback_delivery_count"
    Test_signal.Overflow.Callback_delivery_count;
  check "stats recompute_count" Test_signal.Overflow.Recompute_count;
  check "stats dynamic_scope_invalidations"
    Test_signal.Overflow.Dynamic_scope_invalidations;
  check "stats nodes_became_necessary"
    Test_signal.Overflow.Nodes_became_necessary;
  check "stats nodes_became_unnecessary"
    Test_signal.Overflow.Nodes_became_unnecessary;
  check "stats stream_bridge_drop_count"
    Test_signal.Overflow.Stream_bridge_drop_count

let test_registration_abort_cleanup_failure_is_suppressed () =
  let module Test_signal = Eta_signal_overflow_harness.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let cleanup_ran = ref false in
  expect_fail_with_finalizer_die "registration abort cleanup"
    (counter_overflow "registration primary")
    "registration abort cleanup failure"
    (Eta_eio.Runtime.run rt
       (widen
          (Test_signal.Overflow.registration_cleanup_on_error
             ~cleanup:(fun () ->
               Effect.sync (fun () ->
                   cleanup_ran := true;
                   failwith "registration abort cleanup failure"))
             (Effect.fail (`Counter_overflow "registration primary")))));
  Alcotest.(check bool) "abort cleanup hook ran" true !cleanup_ran

let test_time_timer_generation_overflow_fails_loudly () =
  let module Test_signal = Eta_signal_overflow_harness.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let signal = run_ok rt (Test_signal.Time.interval (Duration.ms 10)) in
  let observer =
    run_ok rt (Test_signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  Test_signal.Overflow.set_timer_generation signal max_int;
  expect_fail "timer generation overflow"
    (counter_overflow "timer generation")
    (Eta_eio.Runtime.run rt (widen (Test_signal.Observer.dispose observer)))

let test_time_timer_start_generation_overflow_is_precommit_failure () =
  let module Test_signal = Eta_signal_overflow_harness.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let use_timer = Test_signal.Var.create false in
  let timer_signal = run_ok rt (Test_signal.Time.interval (Duration.ms 10)) in
  Test_signal.Overflow.set_timer_generation timer_signal max_int;
  let selected =
    Test_signal.bind (Test_signal.Var.watch use_timer) (fun active ->
        if active then timer_signal else Test_signal.const (-1))
  in
  let observer =
    run_ok rt (Test_signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Test_signal.stabilize;
  Alcotest.(check int) "initial inactive branch" (-1)
    (run_ok rt (Test_signal.Observer.read observer));
  run_ok rt (Test_signal.Var.set use_timer true);
  expect_fail "timer start generation overflow"
    (counter_overflow "timer generation")
    (Eta_eio.Runtime.run rt (widen Test_signal.stabilize));
  Alcotest.(check int) "snapshot did not switch after overflow" (-1)
    (run_ok rt (Test_signal.Observer.read observer))

let test_external_timer_stop_generation_overflow_is_precommit_failure () =
  let module Test_signal = Eta_signal_overflow_harness.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let use_timer = Test_signal.Var.create true in
  let timer_signal = run_ok rt (Test_signal.Time.interval (Duration.ms 10)) in
  let selected =
    Test_signal.bind (Test_signal.Var.watch use_timer) (fun active ->
        if active then timer_signal else Test_signal.const (-1))
  in
  let observer =
    run_ok rt (Test_signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Test_signal.stabilize;
  wait_for_sleepers clock 1;
  let previous_value = run_ok rt (Test_signal.Observer.read observer) in
  Test_signal.Overflow.set_timer_generation timer_signal max_int;
  run_ok rt (Test_signal.Var.set use_timer false);
  expect_fail "external timer stop generation overflow"
    (counter_overflow "timer generation")
    (Eta_eio.Runtime.run rt (widen Test_signal.stabilize));
  Alcotest.(check int) "snapshot did not switch after stop overflow"
    previous_value
    (run_ok rt (Test_signal.Observer.read observer));
  Test_signal.Overflow.set_timer_generation timer_signal 0;
  run_ok rt (Test_signal.Observer.dispose observer)

let () =
  Alcotest.run "eta_signal_overflow"
    [
      ( "overflow",
        [
          Alcotest.test_case "version overflow does not publish snapshot" `Quick
            test_signal_version_overflow_does_not_publish_partial_snapshot;
          Alcotest.test_case "var create counter overflow raises graph error"
            `Quick test_var_create_counter_overflow_raises_graph_error;
          Alcotest.test_case "stabilization generation overflow typed failure"
            `Quick test_stabilization_generation_overflow_is_typed_failure;
          Alcotest.test_case "timer refresh token overflow typed failure" `Quick
            test_timer_refresh_token_overflow_is_typed_failure;
          Alcotest.test_case "stats counter saturation is typed failure" `Quick
            test_stats_counter_saturation_is_typed_failure;
          Alcotest.test_case
            "registration abort cleanup failure is suppressed" `Quick
            test_registration_abort_cleanup_failure_is_suppressed;
          Alcotest.test_case "time timer generation overflow fails loudly"
            `Quick test_time_timer_generation_overflow_fails_loudly;
          Alcotest.test_case
            "time timer start overflow is precommit failure" `Quick
            test_time_timer_start_generation_overflow_is_precommit_failure;
          Alcotest.test_case
            "external timer stop overflow is precommit failure" `Quick
            test_external_timer_stop_generation_overflow_is_precommit_failure;
        ] );
    ]
