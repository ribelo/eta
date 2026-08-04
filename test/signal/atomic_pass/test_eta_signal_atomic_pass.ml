module Atomic = Eta_signal_atomic_pass
module Cleanup = Eta_signal_cleanup
module Commit_plan = Eta_signal_commit_plan
module Node = Eta_signal_node
module Scope = Eta_signal_scope
module Transaction = Eta_signal_transaction

type error = [ `Reentrant_stabilization ]

type fixture = {
  atomic : (unit, error) Atomic.t;
  cell : int Transaction.staged;
  mutable pending : int list;
  mutable cleanup_calls : int;
}

let create_fixture () =
  {
    atomic = Atomic.create ();
    cell = Transaction.create_staged 0;
    pending = [ 1 ];
    cleanup_calls = 0;
  }

let ops fixture =
  Atomic.ops
    ~reentrant_error:`Reentrant_stabilization
    ~classify_graph_error:(fun _ -> None)
    ~advance_generation:(fun () -> ())
    ~begin_staging:(fun () -> ())
    ~drain_pending:(fun () ->
      let pending = fixture.pending in
      fixture.pending <- [];
      pending)
    ~release_pending_marks:(fun () _ -> ())
    ~observer_snapshot:(fun () ->
      Atomic.observer_snapshot ~observers:[]
        ~collect_events:(fun () _ -> [])
        ~mark_events_pending:(fun () _ -> ()))
    ~stage_pending:(fun () pending ->
      List.iter
        (Transaction.stage (Atomic.active_transaction fixture.atomic) fixture.cell)
        pending)
    ~plan_dynamic:(fun () _ -> ())
    ~prepare_commit:(fun () () ->
      Ok (Atomic.new_commit_plan fixture.atomic))
    ~update_necessity:(fun () -> ())
    ~clear_timer_refresh:(fun () -> ())
    ~rollback_staging:(fun () () ->
      Atomic.rollback_transaction fixture.atomic;
      fixture.cleanup_calls <- fixture.cleanup_calls + 1;
      [])
    ~mark_observers_failed:(fun () _ -> ())
    ~requeue_pending:(fun () pending ->
      fixture.pending <- pending @ fixture.pending)

let outcome result =
  Atomic.result result
    ~planning_ok:(fun ~hooks:_ ~events:_ -> `Ok)
    ~graph_error:(fun ~hooks:_ error -> `Error error)
    ~defect:(fun ~hooks:_ exn _ -> `Defect exn)

let run fixture = Atomic.run fixture.atomic () (ops fixture)

let expect_fault expected = function
  | `Defect actual when actual == expected -> ()
  | `Defect actual ->
      Alcotest.failf "wrong defect: %s" (Printexc.to_string actual)
  | `Ok -> Alcotest.fail "expected defect, got success"
  | `Error _ -> Alcotest.fail "expected defect, got typed failure"

let finish_success fixture result =
  Alcotest.(check bool) "successful retry" true (outcome result = `Ok);
  Atomic.finish_delivering fixture.atomic;
  Alcotest.(check bool) "returned to idle" true
    (Atomic.phase fixture.atomic = Atomic.Idle)

let test_atomic_phase_entry_allocation_defect_preserves_idle_and_retryable_work () =
  let fixture = create_fixture () in
  let defect = Failure "allocation" in
  Atomic.set_fault (Atomic.fault_injector fixture.atomic)
    (Some { slot = Before_phase_install; exn = defect });
  run fixture |> outcome |> expect_fault defect;
  Alcotest.(check bool) "phase stayed idle" true
    (Atomic.phase fixture.atomic = Atomic.Idle);
  Alcotest.(check int) "committed value unchanged" 0
    (Transaction.current fixture.cell);
  Alcotest.(check (list int)) "work stayed queued" [ 1 ] fixture.pending;
  Atomic.set_fault (Atomic.fault_injector fixture.atomic) None;
  finish_success fixture (run fixture);
  Alcotest.(check int) "published once" 1 (Transaction.current fixture.cell)

let planning_slots =
  [
    Atomic.After_phase_install;
    After_dynamic_discovery;
    After_frontier_freeze;
    After_discard_partition;
    After_prospective_validation;
    Before_plan_seal;
    Before_total_commit;
  ]

let test_generated_planning_faults_roll_back_exactly_and_retry () =
  List.iter
    (fun slot ->
      let fixture = create_fixture () in
      let defect = Failure "planning fault" in
      Atomic.set_fault (Atomic.fault_injector fixture.atomic)
        (Some { slot; exn = defect });
      run fixture |> outcome |> expect_fault defect;
      Alcotest.(check bool) "phase after rollback" true
        (Atomic.phase fixture.atomic = Atomic.Idle);
      Alcotest.(check int) "committed value after rollback" 0
        (Transaction.current fixture.cell);
      Alcotest.(check (list int)) "pending work requeued" [ 1 ] fixture.pending;
      Atomic.set_fault (Atomic.fault_injector fixture.atomic) None;
      finish_success fixture (run fixture);
      Alcotest.(check int) "retry published" 1
        (Transaction.current fixture.cell))
    planning_slots

let test_total_commit_interprets_only_prepared_writes () =
  let counters = Commit_plan.create_counters () in
  Commit_plan.reset_counters counters;
  let plan = Commit_plan.create counters in
  let trace = ref [] in
  Commit_plan.add_write plan (fun () ->
      trace := 1 :: !trace;
      []);
  Commit_plan.add_write plan (fun () ->
      trace := 2 :: !trace;
      []);
  let sealed = Commit_plan.seal plan in
  ignore (Commit_plan.apply sealed : unit list);
  Alcotest.(check (list int)) "prepared order" [ 2; 1 ] !trace;
  let snapshot = Commit_plan.counter_snapshot counters in
  Alcotest.(check int) "one sealed plan" 1 snapshot.sealed_plans;
  Alcotest.(check int) "two prepared writes" 2 snapshot.prepared_writes;
  Alcotest.(check int) "two applied writes" 2 snapshot.applied_writes

let test_cleanup_resources_have_one_terminal_transition () =
  let counters = Cleanup.create_counters () in
  Cleanup.reset_counters counters;
  let ledger = Cleanup.create_ledger counters in
  let calls = ref 0 in
  let resource = Cleanup.register ledger (fun () -> incr calls) in
  let hook =
    match Cleanup.transition ledger resource Cleanup.Discarded with
    | Ok (Some hook) -> hook
    | Ok None | Error `Already_terminal -> Alcotest.fail "missing discard hook"
  in
  hook ();
  (match Cleanup.transition ledger resource Cleanup.Committed with
  | Error `Already_terminal -> ()
  | Ok _ -> Alcotest.fail "duplicate terminal transition accepted");
  Alcotest.(check int) "hook once" 1 !calls;
  Alcotest.(check int) "no pending resources" 0
    (Cleanup.pending_resources ledger);
  let snapshot = Cleanup.counter_snapshot counters in
  Alcotest.(check int) "one registration" 1 snapshot.resource_registrations;
  Alcotest.(check int) "one terminal" 1 snapshot.terminal_transitions;
  Alcotest.(check int) "one duplicate rejection" 1
    snapshot.duplicate_transition_rejections

let test_node_and_scope_lifetimes_are_one_way () =
  let lifetime = Node.create () in
  Alcotest.(check bool) "live" true (Node.is_live lifetime);
  Alcotest.(check bool) "first invalidation" true (Node.invalidate lifetime);
  Alcotest.(check bool) "second invalidation" false (Node.invalidate lifetime);
  Alcotest.(check bool) "stays invalid" false (Node.is_live lifetime);
  let scope = Scope.create ~id:1 ~owner:() ~parent:None in
  Scope.add_node scope "node";
  Alcotest.(check (option (list string))) "scope returns members once"
    (Some [ "node" ]) (Scope.invalidate scope);
  Alcotest.(check (option (list string))) "scope cannot become live again" None
    (Scope.invalidate scope)

let () =
  Alcotest.run "eta_signal_atomic_pass"
    [
      ( "atomic pass",
        [
          Alcotest.test_case
            "test_atomic_phase_entry_allocation_defect_preserves_idle_and_retryable_work"
            `Quick
            test_atomic_phase_entry_allocation_defect_preserves_idle_and_retryable_work;
          Alcotest.test_case
            "signal generated planning faults roll back exactly and retry with empty census"
            `Quick test_generated_planning_faults_roll_back_exactly_and_retry;
          Alcotest.test_case
            "test_total_commit_interprets_only_prepared_writes" `Quick
            test_total_commit_interprets_only_prepared_writes;
          Alcotest.test_case "cleanup resources transition once" `Quick
            test_cleanup_resources_have_one_terminal_transition;
          Alcotest.test_case "node and scope lifetimes are one way" `Quick
            test_node_and_scope_lifetimes_are_one_way;
        ] );
    ]
