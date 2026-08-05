module E = Eta.Effect
module S = Eta_signal_kernel.Make_no_error ()

type test_error =
  [ S.graph_error | S.observer_read_error | S.stabilize_error | S.time_error ]

let widen (eff : ('a, [< test_error ]) E.t) : ('a, test_error) E.t =
  E.map_error (fun error -> (error :> test_error)) eff

let run_ok runtime eff =
  Eta_test.Expect.expect_ok (Eta.Runtime.run runtime (widen eff))

let test_affected_child_notification_avoids_scan () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let left_source = S.Var.create 1 in
  let right_source = S.Var.create 10 in
  let left_child = S.Var.watch left_source |> S.map (fun value -> value + 1) in
  let right_child =
    S.Var.watch right_source |> S.map (fun value -> value + 1)
  in
  let left_notifications = ref 0 in
  let right_notifications = ref 0 in
  let left_listener () = incr left_notifications in
  let right_listener () = incr right_notifications in
  S.Extension.add_dirty_listener left_child left_listener;
  S.Extension.add_dirty_listener right_child right_listener;
  let combined = S.map2 ( + ) left_child right_child in
  let observer =
    run_ok runtime (S.Observer.observe combined (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  left_notifications := 0;
  right_notifications := 0;
  run_ok runtime (S.Var.set left_source 2);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "affected child notified once" 1 !left_notifications;
  Alcotest.(check int) "unaffected child not visited" 0 !right_notifications;
  S.Extension.remove_dirty_listener left_child left_listener;
  S.Extension.remove_dirty_listener right_child right_listener;
  run_ok runtime (S.Observer.dispose observer)

let test_preflight_orders_owner_before_descendant () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let source = S.Var.create 1 in
  let descendant = ref None in
  let owner =
    S.bind (S.Var.watch source) ~f:(fun value ->
        let child = S.const value |> S.map Fun.id in
        descendant := Some child;
        child)
  in
  let observer = run_ok runtime (S.Observer.observe owner (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  let descendant =
    match !descendant with
    | Some descendant -> descendant
    | None -> Alcotest.fail "missing descendant"
  in
  let order = ref [] in
  let owner_plan =
    S.Extension.preflight_plan owner (fun () -> order := !order @ [ "owner" ])
  in
  let descendant_plan =
    S.Extension.preflight_plan descendant (fun () ->
        order := !order @ [ "descendant" ])
  in
  S.Extension.preflight_owner_before_descendant
    [ descendant_plan; owner_plan ];
  Alcotest.(check (list string)) "preflight order"
    [ "owner"; "descendant" ] !order;
  run_ok runtime (S.Observer.dispose observer)

let test_demand_loss_removes_unclaimed_scheduler_work () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let source = S.Var.create 1 in
  let signal = S.Var.watch source |> S.map succ in
  let observer = run_ok runtime (S.Observer.observe signal (fun _ -> E.unit)) in
  Alcotest.(check bool) "scheduler has initialization work" false
    (S.Extension.scheduler_empty ());
  run_ok runtime (S.Observer.dispose observer);
  Alcotest.(check bool) "scheduler empty after demand loss" true
    (S.Extension.scheduler_empty ());
  Alcotest.(check int) "work ledger empty after demand loss" 0
    (S.Extension.actionable_work_count ())

let test_quiescent_stabilize_is_constant () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let source = S.Var.create 1 in
  let signal = S.Var.watch source |> S.map succ in
  let observer = run_ok runtime (S.Observer.observe signal (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  S.Extension.reset_counters ();
  let generation_before = run_ok runtime (S.Extension.generation ()) in
  run_ok runtime S.stabilize;
  let generation_after = run_ok runtime (S.Extension.generation ()) in
  let atomic = S.Extension.atomic_pass_counter_snapshot () in
  let work = S.Extension.work_counter_snapshot () in
  Alcotest.(check int) "one admission check" 1 work.admission_checks;
  Alcotest.(check int) "one quiescent return" 1 work.quiescent_returns;
  Alcotest.(check int) "no phase entry" 0 atomic.phase_entries;
  Alcotest.(check int) "no commit" 0 atomic.commits;
  Alcotest.(check int) "no rollback" 0 atomic.rollback_calls;
  Alcotest.(check int) "no idle transition" 0 atomic.returns_to_idle;
  Alcotest.(check int) "no snapshot increment" generation_before
    generation_after;
  run_ok runtime (S.Observer.dispose observer)

let test_dirty_diamond_settles_dependencies_first () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let source = S.Var.create 1 in
  let input = S.Var.watch source in
  let shared = S.map succ input in
  let left = S.map succ shared in
  let right = S.map succ shared in
  let total = S.map2 ( + ) left right in
  let observer = run_ok runtime (S.Observer.observe total (fun _ -> E.unit)) in
  let order = ref [] in
  let listen label signal =
    S.Extension.add_dirty_listener signal (fun () ->
        order := label :: !order)
  in
  listen "shared" shared;
  listen "left" left;
  listen "right" right;
  listen "total" total;
  run_ok runtime S.stabilize;
  order := [];
  S.Extension.reset_counters ();
  run_ok runtime (S.Var.set source 2);
  run_ok runtime S.stabilize;
  let scheduler = S.Extension.scheduler_counter_snapshot () in
  Alcotest.(check (list string)) "dependency-first evaluation order"
    [ "shared"; "left"; "right"; "total" ] (List.rev !order);
  Alcotest.(check int) "five scheduler claims" 5 scheduler.claims;
  Alcotest.(check int) "five dependency edge visits" 5
    scheduler.dependency_edge_visits;
  Alcotest.(check int) "five node evaluations" 5 scheduler.node_evaluations;
  Alcotest.(check bool) "scheduler empty after commit" true
    (S.Extension.scheduler_empty ());
  Alcotest.(check int) "work ledger empty after commit" 0
    (S.Extension.actionable_work_count ());
  run_ok runtime (S.Observer.dispose observer)

let test_timer_work_blocks_quiescent_stabilize () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let timer = run_ok runtime (S.Time.interval (Eta.Duration.ms 10)) in
  let observer = run_ok runtime (S.Observer.observe timer (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  Alcotest.(check int) "demanded timer owns reconciliation work" 1
    (S.Extension.timer_reconciliation_work_count ());
  S.Extension.reset_counters ();
  run_ok runtime S.stabilize;
  let atomic = S.Extension.atomic_pass_counter_snapshot () in
  let work = S.Extension.work_counter_snapshot () in
  Alcotest.(check int) "demanded timer enters stabilization" 1
    atomic.phase_entries;
  Alcotest.(check int) "demanded timer is not quiescent" 0
    work.quiescent_returns;
  run_ok runtime (S.Observer.dispose observer);
  Alcotest.(check int) "timer work released after demand loss" 0
    (S.Extension.timer_reconciliation_work_count ());
  S.Extension.reset_counters ();
  run_ok runtime S.stabilize;
  let atomic = S.Extension.atomic_pass_counter_snapshot () in
  let work = S.Extension.work_counter_snapshot () in
  Alcotest.(check int) "stopped timer skips phase entry" 0 atomic.phase_entries;
  Alcotest.(check int) "stopped timer is quiescent" 1 work.quiescent_returns

let test_cleanup_hooks_own_pending_work () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let source = S.Var.create 1 in
  let signal = S.map succ (S.Var.watch source) in
  let seen_cleanup_count = ref None in
  let observer =
    run_ok runtime
      (S.Observer.observe_delivery
         ~on_finish:
           [
             (fun _reason ->
               seen_cleanup_count := Some (S.Extension.cleanup_work_count ()));
           ]
         signal
         (fun _delivery -> E.unit))
  in
  run_ok runtime S.stabilize;
  Alcotest.(check int) "no cleanup work while observer is live" 0
    (S.Extension.cleanup_work_count ());
  run_ok runtime (S.Observer.dispose observer);
  Alcotest.(check (option int)) "finish hook observes pending cleanup work"
    (Some 1) !seen_cleanup_count;
  Alcotest.(check int) "cleanup work released after finish hook" 0
    (S.Extension.cleanup_work_count ());
  S.Extension.reset_counters ();
  run_ok runtime S.stabilize;
  let atomic = S.Extension.atomic_pass_counter_snapshot () in
  let work = S.Extension.work_counter_snapshot () in
  Alcotest.(check int) "no cleanup means no phase entry" 0 atomic.phase_entries;
  Alcotest.(check int) "no cleanup is quiescent" 1 work.quiescent_returns

let test_observer_delivery_counters_cover_plan_and_delivery () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let source = S.Var.create 1 in
  let signal = S.Var.watch source |> S.map succ in
  let unrelated_source = S.Var.create 10 in
  let unrelated_signal =
    S.Var.watch unrelated_source |> S.map (fun value -> value + 10)
  in
  let observer = run_ok runtime (S.Observer.observe signal (fun _ -> E.unit)) in
  let unrelated_observer =
    run_ok runtime (S.Observer.observe unrelated_signal (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  S.Extension.reset_counters ();
  run_ok runtime (S.Var.set source 2);
  run_ok runtime S.stabilize;
  let plan = S.Extension.observer_plan_counter_snapshot () in
  let delivery = S.Extension.observer_delivery_counter_snapshot () in
  Alcotest.(check int) "one candidate visit" 1 plan.candidate_visits;
  Alcotest.(check int) "two union node visits" 2 plan.union_node_visits;
  Alcotest.(check int) "one union edge visit" 1 plan.union_edge_visits;
  Alcotest.(check int) "one ready push" 1 plan.ready_pushes;
  Alcotest.(check int) "one ready pop" 1 plan.ready_pops;
  Alcotest.(check int) "no pairwise search" 0 plan.pairwise_search_visits;
  Alcotest.(check int) "one lifecycle check" 1 delivery.lifecycle_checks;
  Alcotest.(check int) "one callback attempt" 1 delivery.callback_attempts;
  Alcotest.(check int) "one acknowledgement attempt" 1
    delivery.acknowledgement_attempts;
  Alcotest.(check int) "one acknowledgement success" 1
    delivery.acknowledgement_successes;
  Alcotest.(check int) "no delivery release" 0 delivery.releases;
  Alcotest.(check int) "no terminal skip" 0 delivery.terminal_skips;
  run_ok runtime (S.Observer.dispose observer);
  run_ok runtime (S.Observer.dispose unrelated_observer)

let test_observer_finish_runs_exactly_once () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let idle_source = S.Var.create 1 in
  let idle_signal = S.Var.watch idle_source in
  let idle_finish_count = ref 0 in
  let idle_callback_count = ref 0 in
  let idle_observer =
    run_ok runtime
      (S.Observer.observe_delivery
         ~on_finish:[ (fun _reason -> incr idle_finish_count) ]
         idle_signal
         (fun _delivery ->
           incr idle_callback_count;
           E.unit))
  in
  run_ok runtime (S.Observer.dispose idle_observer);
  run_ok runtime (S.Observer.dispose idle_observer);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "idle finish runs once" 1 !idle_finish_count;
  Alcotest.(check int) "idle disposal skips callback" 0 !idle_callback_count;

  let running_source = S.Var.create 1 in
  let running_signal = S.Var.watch running_source in
  let running_finish_count = ref 0 in
  let running_callback_count = ref 0 in
  let running_observer = ref None in
  let observer =
    run_ok runtime
      (S.Observer.observe_delivery
         ~on_finish:[ (fun _reason -> incr running_finish_count) ]
         running_signal
         (fun _delivery ->
           incr running_callback_count;
           match !running_observer with
           | Some observer ->
               S.Observer.dispose observer
               |> E.or_die (fun error -> S.Graph_error error)
           | None -> E.unit))
  in
  running_observer := Some observer;
  run_ok runtime S.stabilize;
  run_ok runtime (S.Observer.dispose observer);
  run_ok runtime (S.Var.set running_source 2);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "running finish runs once" 1 !running_finish_count;
  Alcotest.(check int) "running callback completed once" 1
    !running_callback_count

let () =
  Alcotest.run "eta_signal_kernel"
    [
      ( "extension",
        [
          Alcotest.test_case "affected child notification avoids scan" `Quick
            test_affected_child_notification_avoids_scan;
          Alcotest.test_case "preflight orders owner before descendant" `Quick
            test_preflight_orders_owner_before_descendant;
          Alcotest.test_case "demand loss removes unclaimed scheduler work"
            `Quick test_demand_loss_removes_unclaimed_scheduler_work;
          Alcotest.test_case "quiescent stabilize is constant" `Quick
            test_quiescent_stabilize_is_constant;
          Alcotest.test_case "dirty diamond settles dependencies first" `Quick
            test_dirty_diamond_settles_dependencies_first;
          Alcotest.test_case "timer work blocks quiescent stabilize" `Quick
            test_timer_work_blocks_quiescent_stabilize;
          Alcotest.test_case "cleanup hooks own pending work" `Quick
            test_cleanup_hooks_own_pending_work;
          Alcotest.test_case "observer delivery counters cover plan and delivery"
            `Quick test_observer_delivery_counters_cover_plan_and_delivery;
          Alcotest.test_case "observer finish runs exactly once" `Quick
            test_observer_finish_runs_exactly_once;
        ] );
    ]
