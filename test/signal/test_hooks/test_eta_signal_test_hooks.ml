module Effect = Eta.Effect
module Test_hooks = Eta_signal_test_hooks

let run_ok runtime eff =
  match Eta_eio.Runtime.run runtime eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected Ok, got %a"
        (Eta.Cause.pp (fun ppf _ -> Format.pp_print_string ppf "<error>"))
        cause

let test_hook_restore () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let state = Test_hooks.create () in
  let calls = ref 0 in
  let action =
    {
      Test_hooks.run =
        (fun () -> Effect.sync (fun () -> calls := !calls + 1));
    }
  in
  Test_hooks.with_hook state Test_hooks.After_graph_lane_acquired action
    (fun () ->
      run_ok runtime (Test_hooks.run state Test_hooks.After_graph_lane_acquired);
      Alcotest.(check int) "hook ran" 1 !calls);
  run_ok runtime (Test_hooks.run state Test_hooks.After_graph_lane_acquired);
  Alcotest.(check int) "hook restored" 1 !calls

let test_counters_and_overrides () =
  let state = Test_hooks.create () in
  Test_hooks.note_lane_waiter_enqueued state;
  Test_hooks.note_lane_waiter_enqueued state;
  Test_hooks.note_lane_waiter_compaction state;
  Test_hooks.set_stats_count_override state Test_hooks.Stats_total_node_count
    (Some 12);
  Alcotest.(check int)
    "enqueued count" 2
    (Test_hooks.lane_waiter_enqueued_count state);
  Alcotest.(check int)
    "compaction count" 1
    (Test_hooks.lane_waiter_compaction_count state);
  Alcotest.(check (option int))
    "stats override" (Some 12)
    (Test_hooks.stats_count_override state Test_hooks.Stats_total_node_count)

let test_clear_resets_state () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let state = Test_hooks.create () in
  let calls = ref 0 in
  let mismatches = ref 0 in
  let action =
    {
      Test_hooks.run =
        (fun () -> Effect.sync (fun () -> calls := !calls + 1));
    }
  in
  Test_hooks.with_hook state Test_hooks.After_stream_drop_before_ack action
    (fun () -> ());
  Test_hooks.note_lane_waiter_enqueued state;
  Test_hooks.note_lane_waiter_compaction state;
  Test_hooks.set_stats_count_override state Test_hooks.Stats_dead_node_count
    (Some 7);
  Test_hooks.set_timer_runtime_mismatch_hook state (fun () ->
      mismatches := !mismatches + 1);
  Test_hooks.clear state;
  run_ok runtime (Test_hooks.run state Test_hooks.After_stream_drop_before_ack);
  Test_hooks.run_timer_runtime_mismatch_hook state;
  Alcotest.(check int) "hook cleared" 0 !calls;
  Alcotest.(check int) "timer hook cleared" 0 !mismatches;
  Alcotest.(check int)
    "enqueued count reset" 0
    (Test_hooks.lane_waiter_enqueued_count state);
  Alcotest.(check int)
    "compaction count reset" 0
    (Test_hooks.lane_waiter_compaction_count state);
  Alcotest.(check (option int))
    "stats override reset" None
    (Test_hooks.stats_count_override state Test_hooks.Stats_dead_node_count)

let () =
  Alcotest.run "eta_signal_test_hooks"
    [
      ( "test_hooks",
        [
          Alcotest.test_case "hook restore" `Quick test_hook_restore;
          Alcotest.test_case "counters and overrides" `Quick
            test_counters_and_overrides;
          Alcotest.test_case "clear resets state" `Quick
            test_clear_resets_state;
        ] );
    ]
