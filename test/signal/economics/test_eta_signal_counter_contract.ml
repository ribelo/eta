let int = Alcotest.(check int)

let test_atomic_pass () =
  let counters = Eta_signal_atomic_pass.create_counters () in
  Eta_signal_atomic_pass.note_phase_entry counters;
  let initial = Eta_signal_atomic_pass.counter_snapshot counters in
  int "disabled" 0 initial.phase_entries;
  Eta_signal_atomic_pass.reset_counters counters;
  Eta_signal_atomic_pass.note_phase_entry counters;
  Eta_signal_atomic_pass.note_commit counters;
  Eta_signal_atomic_pass.note_rollback counters;
  Eta_signal_atomic_pass.note_return_to_idle counters;
  let actual = Eta_signal_atomic_pass.counter_snapshot counters in
  int "phase entries" 1 actual.phase_entries;
  int "commits" 1 actual.commits;
  int "rollbacks" 1 actual.rollback_calls;
  int "idle returns" 1 actual.returns_to_idle

let test_commit_plan () =
  let counters = Eta_signal_commit_plan.create_counters () in
  Eta_signal_commit_plan.reset_counters counters;
  Eta_signal_commit_plan.note_sealed_plan counters;
  Eta_signal_commit_plan.note_prepared_write counters;
  Eta_signal_commit_plan.note_applied_write counters;
  Eta_signal_commit_plan.note_cycle_node counters;
  Eta_signal_commit_plan.note_cycle_edge counters;
  let actual = Eta_signal_commit_plan.counter_snapshot counters in
  int "sealed plans" 1 actual.sealed_plans;
  int "prepared writes" 1 actual.prepared_writes;
  int "applied writes" 1 actual.applied_writes;
  int "cycle nodes" 1 actual.cycle_nodes;
  int "cycle edges" 1 actual.cycle_edges

let test_work_and_scheduler () =
  let work = Eta_signal_work.create_counters () in
  Eta_signal_work.reset_counters work;
  Eta_signal_work.note_admission_check work;
  Eta_signal_work.note_quiescent_return work;
  Eta_signal_work.note_work_class_zero_crossing work;
  let work = Eta_signal_work.counter_snapshot work in
  int "admission checks" 1 work.admission_checks;
  int "quiescent returns" 1 work.quiescent_returns;
  int "work zero crossings" 1 work.work_class_zero_crossings;
  let scheduler = Eta_signal_scheduler.create_counters () in
  Eta_signal_scheduler.reset_counters scheduler;
  Eta_signal_scheduler.note_admission scheduler;
  Eta_signal_scheduler.note_claim scheduler;
  Eta_signal_scheduler.note_dependency_edge_visit scheduler;
  Eta_signal_scheduler.note_propagation_edge_visit scheduler;
  Eta_signal_scheduler.note_node_evaluation scheduler;
  Eta_signal_scheduler.note_cutoff_call scheduler;
  let scheduler = Eta_signal_scheduler.counter_snapshot scheduler in
  int "scheduler admissions" 1 scheduler.admissions;
  int "scheduler claims" 1 scheduler.claims;
  int "dependency visits" 1 scheduler.dependency_edge_visits;
  int "propagation visits" 1 scheduler.propagation_edge_visits;
  int "node evaluations" 1 scheduler.node_evaluations;
  int "cutoff calls" 1 scheduler.cutoff_calls

let test_demand_and_topology () =
  let demand = Eta_signal_demand.create_counters () in
  Eta_signal_demand.reset_counters demand;
  Eta_signal_demand.note_reference_operation demand;
  Eta_signal_demand.note_zero_boundary demand;
  Eta_signal_demand.note_dependency_edge_visit demand;
  Eta_signal_demand.note_timer_desired_state_transition demand;
  let demand = Eta_signal_demand.counter_snapshot demand in
  int "reference operations" 1 demand.reference_operations;
  int "zero boundaries" 1 demand.zero_boundaries;
  int "demand edge visits" 1 demand.dependency_edge_visits;
  int "timer desired transitions" 1 demand.timer_desired_state_transitions;
  let topology = Eta_signal_topology.create_counters () in
  Eta_signal_topology.reset_counters topology;
  Eta_signal_topology.note_static_insert topology;
  Eta_signal_topology.note_dynamic_insert topology;
  Eta_signal_topology.note_indexed_removal topology;
  Eta_signal_topology.note_slot_repair topology;
  Eta_signal_topology.note_invalidated_node topology;
  let topology = Eta_signal_topology.counter_snapshot topology in
  int "static inserts" 1 topology.static_inserts;
  int "dynamic inserts" 1 topology.dynamic_inserts;
  int "indexed removals" 1 topology.indexed_removals;
  int "slot repairs" 1 topology.slot_repairs;
  int "invalidations" 1 topology.invalidated_nodes;
  int "adjacency searches" 0 topology.adjacency_search_steps

let test_stable_family_and_observers () =
  let family = Eta_signal_stable_family_plan.create_counters () in
  Eta_signal_stable_family_plan.reset_counters family;
  Eta_signal_stable_family_plan.note_input_comparison family;
  Eta_signal_stable_family_plan.note_diff_event family;
  Eta_signal_stable_family_plan.note_selected_child_visit family;
  Eta_signal_stable_family_plan.note_provisional_addition family;
  Eta_signal_stable_family_plan.note_commit family;
  Eta_signal_stable_family_plan.note_discard family;
  let family = Eta_signal_stable_family_plan.counter_snapshot family in
  int "input comparisons" 1 family.input_comparisons;
  int "diff events" 1 family.diff_events;
  int "child visits" 1 family.selected_child_visits;
  int "provisional additions" 1 family.provisional_additions;
  int "family commits" 1 family.commits;
  int "family discards" 1 family.discards;
  let plan = Eta_signal_observer_plan.create_counters () in
  Eta_signal_observer_plan.reset_counters plan;
  Eta_signal_observer_plan.note_candidate_visit plan;
  Eta_signal_observer_plan.note_union_node_visit plan;
  Eta_signal_observer_plan.note_union_edge_visit plan;
  Eta_signal_observer_plan.note_ready_push plan;
  Eta_signal_observer_plan.note_ready_pop plan;
  Eta_signal_observer_plan.note_ready_comparison plan;
  let plan = Eta_signal_observer_plan.counter_snapshot plan in
  int "candidate visits" 1 plan.candidate_visits;
  int "union nodes" 1 plan.union_node_visits;
  int "union edges" 1 plan.union_edge_visits;
  int "ready pushes" 1 plan.ready_pushes;
  int "ready pops" 1 plan.ready_pops;
  int "ready comparisons" 1 plan.ready_comparisons;
  int "pairwise visits" 0 plan.pairwise_search_visits;
  let delivery = Eta_signal_observer_delivery.create_counters () in
  Eta_signal_observer_delivery.reset_counters delivery;
  Eta_signal_observer_delivery.note_lifecycle_check delivery;
  Eta_signal_observer_delivery.note_callback_attempt delivery;
  Eta_signal_observer_delivery.note_acknowledgement_attempt delivery;
  Eta_signal_observer_delivery.note_acknowledgement_success delivery;
  Eta_signal_observer_delivery.note_release delivery;
  Eta_signal_observer_delivery.note_terminal_skip delivery;
  let delivery = Eta_signal_observer_delivery.counter_snapshot delivery in
  int "lifecycle checks" 1 delivery.lifecycle_checks;
  int "callback attempts" 1 delivery.callback_attempts;
  int "ack attempts" 1 delivery.acknowledgement_attempts;
  int "ack successes" 1 delivery.acknowledgement_successes;
  int "releases" 1 delivery.releases;
  int "terminal skips" 1 delivery.terminal_skips

let test_timer_cleanup_and_tombstone () =
  let timer = Eta_signal_timer.create_counters () in
  Eta_signal_timer.reset_counters timer;
  Eta_signal_timer.note_reconcile_claim timer;
  Eta_signal_timer.note_start timer;
  Eta_signal_timer.note_stop timer;
  Eta_signal_timer.note_cancellation timer;
  Eta_signal_timer.note_wake timer;
  Eta_signal_timer.note_stale_wake timer;
  Eta_signal_timer.note_cleanup_claim timer;
  let timer = Eta_signal_timer.counter_snapshot timer in
  int "reconcile claims" 1 timer.reconcile_claims;
  int "starts" 1 timer.starts;
  int "stops" 1 timer.stops;
  int "cancellations" 1 timer.cancellations;
  int "wakes" 1 timer.wakes;
  int "stale wakes" 1 timer.stale_wakes;
  int "timer cleanup" 1 timer.cleanup_claims;
  let cleanup = Eta_signal_cleanup.create_counters () in
  Eta_signal_cleanup.reset_counters cleanup;
  Eta_signal_cleanup.note_resource_registration cleanup;
  Eta_signal_cleanup.note_terminal_transition cleanup;
  Eta_signal_cleanup.note_hook_attempt cleanup;
  Eta_signal_cleanup.note_hook_completion cleanup;
  let cleanup = Eta_signal_cleanup.counter_snapshot cleanup in
  int "cleanup registrations" 1 cleanup.resource_registrations;
  int "cleanup transitions" 1 cleanup.terminal_transitions;
  int "hook attempts" 1 cleanup.hook_attempts;
  int "hook completions" 1 cleanup.hook_completions;
  int "duplicate transitions" 0 cleanup.duplicate_transition_rejections;
  let tombstone = Eta_signal_tombstone_index.create_counters () in
  Eta_signal_tombstone_index.reset_counters tombstone;
  Eta_signal_tombstone_index.note_slot_write tombstone;
  Eta_signal_tombstone_index.note_eviction tombstone;
  Eta_signal_tombstone_index.note_iteration_visit tombstone;
  let tombstone = Eta_signal_tombstone_index.counter_snapshot tombstone in
  int "slot writes" 1 tombstone.slot_writes;
  int "evictions" 1 tombstone.evictions;
  int "iteration visits" 1 tombstone.iteration_visits;
  int "duplicate scans" 0 tombstone.duplicate_scan_steps

exception Injected

let test_fault_slots () =
  let module A = Eta_signal_atomic_pass in
  let slots =
    [
      A.Before_phase_install;
      A.After_phase_install;
      A.After_dynamic_discovery;
      A.After_frontier_freeze;
      A.After_discard_partition;
      A.After_prospective_validation;
      A.Before_plan_seal;
      A.Before_total_commit;
    ]
  in
  let injector = A.create_fault_injector () in
  List.iter
    (fun slot ->
      A.set_fault injector (Some { A.slot; exn = Injected });
      Alcotest.check_raises "fault injected" Injected (fun () ->
          A.check_fault injector slot))
    slots

let test_graph_branded_probe () =
  let reset_count = ref 0 in
  let fault = ref None in
  let probe =
    Eta_signal_test_probe.create
      ~reset:(fun () -> incr reset_count)
      ~snapshot:(fun () -> !reset_count)
      ~set_fault:(fun value -> fault := value)
      ~census:(fun () -> [ !reset_count ])
  in
  Eta_signal_test_probe.reset probe;
  int "snapshot" 1 (Eta_signal_test_probe.snapshot probe);
  Eta_signal_test_probe.set_fault probe (Some `Before);
  Alcotest.(check (option string))
    "fault" (Some "before")
    (Option.map (function `Before -> "before") !fault);
  Alcotest.(check (list int))
    "census" [ 1 ] (Eta_signal_test_probe.census probe)

let () =
  Alcotest.run "eta_signal_counter_contract"
    [
      ( "counters",
        [
          Alcotest.test_case "atomic pass" `Quick test_atomic_pass;
          Alcotest.test_case "commit plan" `Quick test_commit_plan;
          Alcotest.test_case "work and scheduler" `Quick
            test_work_and_scheduler;
          Alcotest.test_case "demand and topology" `Quick
            test_demand_and_topology;
          Alcotest.test_case "stable family and observers" `Quick
            test_stable_family_and_observers;
          Alcotest.test_case "timer cleanup tombstone" `Quick
            test_timer_cleanup_and_tombstone;
          Alcotest.test_case "fault slots" `Quick test_fault_slots;
          Alcotest.test_case "graph-branded probe" `Quick
            test_graph_branded_probe;
        ] );
    ]
