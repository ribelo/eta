module Timer = Eta_signal_timer

let pp_deadline_error ppf = function
  | `Past_deadline -> Format.pp_print_string ppf "Past_deadline"
  | `Deadline_overflow -> Format.pp_print_string ppf "Deadline_overflow"

let deadline_error =
  Alcotest.testable pp_deadline_error (fun left right -> left = right)

let pp_timer_error ppf = function
  | `Invalid_interval -> Format.pp_print_string ppf "Invalid_interval"

let timer_error =
  Alcotest.testable pp_timer_error (fun left right -> left = right)

let test_capped_arithmetic () =
  Alcotest.(check int) "add ignores negative" 10 (Timer.add_ms_capped 10 (-2));
  Alcotest.(check int) "add caps" max_int (Timer.add_ms_capped max_int 1);
  Alcotest.(check int) "mul zero" 0 (Timer.mul_ms_capped 10 0);
  Alcotest.(check int) "mul caps" max_int (Timer.mul_ms_capped max_int 2);
  Alcotest.(check int) "int add caps" max_int (Timer.add_int_capped max_int 1)

let test_due_arithmetic () =
  Alcotest.(check int) "not due" 0
    (Timer.missed_cadences ~interval_ms:10 ~next_due_ms:50 ~now_ms:49);
  Alcotest.(check int) "exactly due" 1
    (Timer.missed_cadences ~interval_ms:10 ~next_due_ms:50 ~now_ms:50);
  Alcotest.(check int) "missed multiple" 4
    (Timer.missed_cadences ~interval_ms:10 ~next_due_ms:50 ~now_ms:85);
  Alcotest.(check int) "advance" 90 (Timer.advance_due 50 10 4)

let test_deadline_arithmetic () =
  Alcotest.(check (result int deadline_error)) "positive" (Ok 15)
    (Timer.add_relative_deadline 10 5);
  Alcotest.(check (result int deadline_error)) "past" (Error `Past_deadline)
    (Timer.add_relative_deadline 10 0);
  Alcotest.(check (result int deadline_error)) "overflow"
    (Error `Deadline_overflow)
    (Timer.add_relative_deadline max_int 1)

let test_validation_policy () =
  Alcotest.(check (result unit deadline_error))
    "future deadline"
    (Ok ())
    (Timer.validate_future_deadline ~now_ms:10 ~deadline_ms:11);
  Alcotest.(check (result unit deadline_error))
    "past deadline"
    (Error `Past_deadline)
    (Timer.validate_future_deadline ~now_ms:10 ~deadline_ms:10);
  Alcotest.(check (result unit deadline_error))
    "positive duration"
    (Ok ())
    (Timer.validate_positive_duration_ms 1);
  Alcotest.(check (result unit deadline_error))
    "non-positive duration"
    (Error `Past_deadline)
    (Timer.validate_positive_duration_ms 0);
  Alcotest.(check (result unit timer_error))
    "positive interval"
    (Ok ())
    (Timer.validate_interval_ms 1);
  Alcotest.(check (result unit timer_error))
    "non-positive interval"
    (Error `Invalid_interval)
    (Timer.validate_interval_ms 0)

let test_catch_up_policy () =
  Alcotest.(check int) "every count" 3
    (Timer.catch_up_update_count Catch_up_every_cadence 3);
  Alcotest.(check int) "once count" 1
    (Timer.catch_up_update_count Catch_up_once_per_wake 3);
  Alcotest.(check int) "coalesced count" 1
    (Timer.catch_up_update_count Catch_up_coalesced 3);
  Alcotest.(check int) "every missed" 1
    (Timer.catch_up_update_missed Catch_up_every_cadence 3);
  Alcotest.(check int) "coalesced missed" 3
    (Timer.catch_up_update_missed Catch_up_coalesced 3)

let test_update_batch_policy () =
  Alcotest.(check bool) "no remaining work" true
    (Option.is_none (Timer.update_batch ~remaining:0));
  (match Timer.update_batch ~remaining:3 with
  | Some batch ->
      Alcotest.(check int) "small batch count" 3
        batch.update_batch_count;
      Alcotest.(check int) "small batch remaining" 0
        batch.update_batch_remaining;
      Alcotest.(check bool) "small batch no yield" false
        batch.update_batch_yield
  | None -> Alcotest.fail "expected small batch");
  (match Timer.update_batch ~remaining:65 with
  | Some batch ->
      Alcotest.(check int) "large batch count" 64
        batch.update_batch_count;
      Alcotest.(check int) "large batch remaining" 1
        batch.update_batch_remaining;
      Alcotest.(check bool) "large batch yields" true
        batch.update_batch_yield
  | None -> Alcotest.fail "expected large batch")

let test_daemon_wake_plan () =
  let every =
    Timer.daemon_wake_plan ~catch_up_policy:Catch_up_every_cadence
      ~interval_ms:10 ~next_due_ms:50 ~now_ms:85
  in
  Alcotest.(check int) "every next due" 90 every.wake_next_due_ms;
  Alcotest.(check bool) "every not saturated" false
    every.wake_saturated_due;
  Alcotest.(check int) "every update count" 4 every.wake_update_count;
  Alcotest.(check int) "every update missed" 1 every.wake_update_missed;
  let coalesced =
    Timer.daemon_wake_plan ~catch_up_policy:Catch_up_coalesced
      ~interval_ms:10 ~next_due_ms:50 ~now_ms:85
  in
  Alcotest.(check int) "coalesced update count" 1
    coalesced.wake_update_count;
  Alcotest.(check int) "coalesced update missed" 4
    coalesced.wake_update_missed;
  let not_due =
    Timer.daemon_wake_plan ~catch_up_policy:Catch_up_every_cadence
      ~interval_ms:10 ~next_due_ms:50 ~now_ms:49
  in
  Alcotest.(check int) "not due unchanged" 50 not_due.wake_next_due_ms;
  Alcotest.(check int) "not due no updates" 0 not_due.wake_update_count;
  Alcotest.(check int) "not due missed unused" 0 not_due.wake_update_missed;
  let saturated =
    Timer.daemon_wake_plan ~catch_up_policy:Catch_up_once_per_wake
      ~interval_ms:10 ~next_due_ms:max_int ~now_ms:max_int
  in
  Alcotest.(check int) "saturated due" max_int
    saturated.wake_next_due_ms;
  Alcotest.(check bool) "saturated finishes" true
    saturated.wake_saturated_due

let noop () = ()

let test_state_helpers () =
  let running = Timer.Timer_running (7, Some 10, noop) in
  Alcotest.(check int) "generation" 7 (Timer.state_generation running);
  Alcotest.(check string) "label" "running" (Timer.state_label running);
  Alcotest.(check bool) "active" true (Timer.state_active running);
  Alcotest.(check bool) "finished" false (Timer.state_finished running);
  Alcotest.(check bool) "has current start" true
    (Timer.state_has_current_start running);
  Alcotest.(check (option int)) "running generation" (Some 7)
    (Timer.state_running_generation running);
  Alcotest.(check bool) "has cancel" true (Timer.state_has_cancel running);
  Alcotest.(check bool) "running current" true
    (Timer.state_running_current running 7);
  Alcotest.(check (option int)) "next due" (Some 10)
    (Timer.state_next_due running);
  Alcotest.(check (option int)) "updated next due" (Some 20)
    (Timer.state_next_due (Timer.state_set_next_due running (Some 20)));
  Alcotest.(check int) "with generation" 8
    (Timer.state_generation (Timer.state_with_generation running 8))

let test_debug_snapshot () =
  let running = Timer.Timer_running (7, Some 10, noop) in
  let running_snapshot = Timer.debug_snapshot running in
  Alcotest.(check string)
    "running label"
    "running"
    running_snapshot.debug_state_label;
  Alcotest.(check bool) "running active" true
    running_snapshot.debug_active;
  Alcotest.(check (option int)) "running generation" (Some 7)
    running_snapshot.debug_running_generation;
  Alcotest.(check bool) "running cancel" true
    running_snapshot.debug_has_cancel;
  Alcotest.(check bool) "running finished" false
    running_snapshot.debug_finished;
  Alcotest.(check int) "running state generation" 7
    running_snapshot.debug_generation;
  let finished_snapshot =
    Timer.debug_snapshot (Timer.Timer_finished 8)
  in
  Alcotest.(check string)
    "finished label"
    "finished"
    finished_snapshot.debug_state_label;
  Alcotest.(check bool) "finished active" false
    finished_snapshot.debug_active;
  Alcotest.(check (option int)) "finished generation" None
    finished_snapshot.debug_running_generation;
  Alcotest.(check bool) "finished cancel" false
    finished_snapshot.debug_has_cancel;
  Alcotest.(check bool) "finished state" true
    finished_snapshot.debug_finished;
  Alcotest.(check int) "finished state generation" 8
    finished_snapshot.debug_generation

let test_snapshot_policy () =
  let initial = Timer.initial_snapshot in
  Alcotest.(check string) "initial state" "inactive"
    (Timer.state_label (Timer.snapshot_state initial));
  Alcotest.(check int) "initial generation" 0
    (Timer.state_generation (Timer.snapshot_state initial));
  Alcotest.(check int) "initial refresh token" (-1)
    (Timer.snapshot_on_demand_refresh_token initial);
  let running =
    Timer.snapshot
      ~state:(Timer.Timer_running (7, Some 10, noop))
      ~on_demand_refresh_token:3
  in
  Alcotest.(check int) "snapshot generation" 9
    (Timer.state_generation
       (Timer.snapshot_state
          (Timer.snapshot_with_generation running 9)));
  Alcotest.(check int) "snapshot token update" 4
    (Timer.snapshot_on_demand_refresh_token
       (Timer.snapshot_with_on_demand_refresh_token running 4));
  (match Timer.snapshot_with_next_due running 20 with
  | Some snapshot ->
      Alcotest.(check (option int)) "snapshot due" (Some 20)
        (Timer.state_next_due (Timer.snapshot_state snapshot))
  | None -> Alcotest.fail "expected active timer snapshot update");
  Alcotest.(check bool) "inactive next due rejected" true
    (Option.is_none (Timer.snapshot_with_next_due initial 20))

let test_refresh_context () =
  let calls = ref 0 in
  let current = ref 41 in
  let now_ms () =
    incr calls;
    !current
  in
  let context =
    Timer.create_refresh_context ~token:7 ~runtime_contract:"runtime"
      ~now_ms
  in
  Alcotest.(check int) "token" 7 (Timer.refresh_token context);
  Alcotest.(check string)
    "runtime"
    "runtime"
    (Timer.refresh_runtime_contract context);
  current := 42;
  Alcotest.(check int) "first sample" 42
    (Timer.refresh_sample_now_ms context);
  current := 100;
  Alcotest.(check int) "cached sample" 42
    (Timer.refresh_sample_now_ms context);
  Alcotest.(check int) "sample calls" 1 !calls;
  Alcotest.(check (list int)) "initial dirty items" []
    (Timer.refresh_dirty_items context);
  Timer.set_refresh_dirty_items context [ 1; 2 ];
  Alcotest.(check (list int)) "set dirty items" [ 1; 2 ]
    (Timer.refresh_dirty_items context);
  Timer.clear_refresh_dirty_items context;
  Alcotest.(check (list int)) "cleared dirty items" []
    (Timer.refresh_dirty_items context)

let test_daemon_status_policy () =
  let running = Timer.Timer_running (7, Some 10, noop) in
  let running_uncancellable =
    Timer.Timer_running_uncancellable (7, Some 10)
  in
  let inactive = Timer.Timer_inactive 7 in
  (match Timer.daemon_status running ~generation:7 with
  | Timer.Daemon_continue -> ()
  | Timer.Daemon_stop -> Alcotest.fail "expected running daemon to continue");
  (match Timer.daemon_status running_uncancellable ~generation:7 with
  | Timer.Daemon_continue -> ()
  | Timer.Daemon_stop ->
      Alcotest.fail "expected uncancellable daemon to continue");
  (match Timer.daemon_status running ~generation:8 with
  | Timer.Daemon_stop -> ()
  | Timer.Daemon_continue -> Alcotest.fail "expected stale daemon to stop");
  match Timer.daemon_status inactive ~generation:7 with
  | Timer.Daemon_stop -> ()
  | Timer.Daemon_continue -> Alcotest.fail "expected inactive daemon to stop"

let test_start_and_refresh_policy () =
  let inactive = Timer.Timer_inactive 0 in
  let running = Timer.Timer_running (1, Some 10, noop) in
  let running_uncancellable =
    Timer.Timer_running_uncancellable (1, Some 10)
  in
  let finished = Timer.Timer_finished 1 in
  Alcotest.(check bool) "inactive needs start" true
    (Timer.needs_start ~effective_state:inactive ~current_state:inactive);
  Alcotest.(check bool) "running with current start does not need start" false
    (Timer.needs_start ~effective_state:running ~current_state:running);
  Alcotest.(check bool) "uncancellable effective with inactive current needs start"
    true
    (Timer.needs_start ~effective_state:running_uncancellable
       ~current_state:inactive);
  Alcotest.(check bool) "finished does not need start" false
    (Timer.needs_start ~effective_state:finished ~current_state:finished);
  Alcotest.(check bool) "eligible refresh" true
    (Timer.can_refresh_on_demand ~refresh_operation:true ~current_token:0
       ~staged_token:(-1) ~token:1 ~refresh_when_inactive:false ~active:true
       ~finished:false);
  Alcotest.(check bool) "no operation" false
    (Timer.can_refresh_on_demand ~refresh_operation:false ~current_token:0
       ~staged_token:(-1) ~token:1 ~refresh_when_inactive:true ~active:true
       ~finished:false);
  Alcotest.(check bool) "already refreshed" false
    (Timer.can_refresh_on_demand ~refresh_operation:true ~current_token:1
       ~staged_token:(-1) ~token:1 ~refresh_when_inactive:true ~active:true
       ~finished:false);
  Alcotest.(check bool) "inactive without refresh permission" false
    (Timer.can_refresh_on_demand ~refresh_operation:true ~current_token:0
       ~staged_token:(-1) ~token:1 ~refresh_when_inactive:false ~active:false
       ~finished:false)

let pp_demand_action ppf = function
  | Timer.Demand_none -> Format.pp_print_string ppf "Demand_none"
  | Timer.Demand_start -> Format.pp_print_string ppf "Demand_start"
  | Timer.Demand_stop -> Format.pp_print_string ppf "Demand_stop"

let demand_action =
  Alcotest.testable pp_demand_action (fun left right -> left = right)

let test_demand_policy () =
  let inactive = Timer.Timer_inactive 0 in
  let running = Timer.Timer_running (1, Some 10, noop) in
  let running_uncancellable =
    Timer.Timer_running_uncancellable (1, Some 10)
  in
  let finished = Timer.Timer_finished 1 in
  Alcotest.(check demand_action) "necessary inactive starts" Timer.Demand_start
    (Timer.demand_action ~necessary:true ~effective_state:inactive
       ~current_state:inactive);
  Alcotest.(check demand_action) "necessary running stays" Timer.Demand_none
    (Timer.demand_action ~necessary:true ~effective_state:running
       ~current_state:running);
  Alcotest.(check demand_action) "necessary finished stays" Timer.Demand_none
    (Timer.demand_action ~necessary:true ~effective_state:finished
       ~current_state:finished);
  Alcotest.(check demand_action) "unnecessary running stops" Timer.Demand_stop
    (Timer.demand_action ~necessary:false ~effective_state:running
       ~current_state:running);
  Alcotest.(check demand_action) "unnecessary uncancellable stops"
    Timer.Demand_stop
    (Timer.demand_action ~necessary:false
       ~effective_state:running_uncancellable ~current_state:inactive);
  Alcotest.(check demand_action) "unnecessary inactive stays" Timer.Demand_none
    (Timer.demand_action ~necessary:false ~effective_state:inactive
       ~current_state:inactive);
  Alcotest.(check bool) "running needs stop" true
    (Timer.needs_stop ~effective_state:running);
  Alcotest.(check bool) "inactive does not need stop" false
    (Timer.needs_stop ~effective_state:inactive)

let test_start_policy () =
  let inactive = Timer.Timer_inactive 0 in
  let running = Timer.Timer_running (1, Some 10, noop) in
  let running_uncancellable =
    Timer.Timer_running_uncancellable (1, Some 10)
  in
  let finished = Timer.Timer_finished 1 in
  (match
     Timer.start ~advance_generation:succ ~effective_state:inactive
       ~current_state:inactive
   with
  | Some plan ->
      Alcotest.(check int) "inactive start generation" 1
        plan.start_generation;
      Alcotest.(check int) "inactive start state generation" 1
        (Timer.state_generation plan.start_state)
  | None -> Alcotest.fail "expected inactive start plan");
  (match
     Timer.start ~advance_generation:succ ~effective_state:running
       ~current_state:running
   with
  | Some _ -> Alcotest.fail "expected running no-op"
  | None -> ());
  (match
     Timer.start ~advance_generation:succ ~effective_state:finished
       ~current_state:finished
   with
  | Some _ -> Alcotest.fail "expected finished no-op"
  | None -> ());
  match
    Timer.start ~advance_generation:succ
      ~effective_state:running_uncancellable ~current_state:inactive
  with
  | Some plan ->
      Alcotest.(check int) "staged effective start generation" 1
        plan.start_generation
  | None -> Alcotest.fail "expected staged effective start plan"

let test_begin_start_policy () =
  let starting = Timer.Timer_starting 7 in
  let running = Timer.Timer_running (7, Some 10, noop) in
  (match Timer.begin_start starting ~generation:7 with
  | Some state ->
      Alcotest.(check string) "state" "running_uncancellable"
        (Timer.state_label state);
      Alcotest.(check int) "generation" 7 (Timer.state_generation state);
      Alcotest.(check (option int)) "next due" None
        (Timer.state_next_due state)
  | None -> Alcotest.fail "expected matching start to continue");
  Alcotest.(check bool) "stale start stops" true
    (Option.is_none (Timer.begin_start starting ~generation:8));
  Alcotest.(check bool) "running start stops" true
    (Option.is_none (Timer.begin_start running ~generation:7))

let test_install_cancel_policy () =
  let old_cancelled = ref false in
  let new_cancelled = ref false in
  let old_cancel () = old_cancelled := true in
  let new_cancel () = new_cancelled := true in
  let uncancellable = Timer.Timer_running_uncancellable (7, Some 10) in
  let running = Timer.Timer_running (7, Some 11, old_cancel) in
  let inactive = Timer.Timer_inactive 7 in
  (match
     Timer.install_cancel uncancellable ~generation:7 ~cancel:new_cancel
   with
  | Some state ->
      Alcotest.(check string) "uncancellable state" "running"
        (Timer.state_label state);
      Alcotest.(check (option int)) "uncancellable next due" (Some 10)
        (Timer.state_next_due state);
      List.iter
        (fun hook -> hook ())
        (Timer.finish ~advance_generation:succ state).finish_cancel_hooks;
      Alcotest.(check bool) "new cancel installed" true !new_cancelled
  | None -> Alcotest.fail "expected cancel install");
  new_cancelled := false;
  (match Timer.install_cancel running ~generation:7 ~cancel:new_cancel with
  | Some state ->
      Alcotest.(check (option int)) "running next due" (Some 11)
        (Timer.state_next_due state);
      List.iter
        (fun hook -> hook ())
        (Timer.finish ~advance_generation:succ state).finish_cancel_hooks;
      Alcotest.(check bool) "old cancel replaced" false !old_cancelled;
      Alcotest.(check bool) "new cancel replacement" true !new_cancelled
  | None -> Alcotest.fail "expected cancel replacement");
  Alcotest.(check bool) "stale generation ignored" true
    (Option.is_none
       (Timer.install_cancel running ~generation:8 ~cancel:new_cancel));
  Alcotest.(check bool) "inactive ignored" true
    (Option.is_none
       (Timer.install_cancel inactive ~generation:7 ~cancel:new_cancel))

let test_mark_stopped_policy () =
  let running_uncancellable =
    Timer.Timer_running_uncancellable (7, Some 10)
  in
  let running = Timer.Timer_running (7, Some 11, noop) in
  let inactive = Timer.Timer_inactive 7 in
  (match Timer.mark_stopped running_uncancellable ~generation:7 with
  | Some state ->
      Alcotest.(check string) "uncancellable stopped" "inactive"
        (Timer.state_label state);
      Alcotest.(check int) "uncancellable generation" 7
        (Timer.state_generation state)
  | None -> Alcotest.fail "expected uncancellable stopped state");
  (match Timer.mark_stopped running ~generation:7 with
  | Some state ->
      Alcotest.(check string) "running stopped" "inactive"
        (Timer.state_label state);
      Alcotest.(check int) "running generation" 7
        (Timer.state_generation state)
  | None -> Alcotest.fail "expected running stopped state");
  Alcotest.(check bool) "stale running ignored" true
    (Option.is_none (Timer.mark_stopped running ~generation:8));
  Alcotest.(check bool) "inactive ignored" true
    (Option.is_none (Timer.mark_stopped inactive ~generation:7))

let test_mark_failed_policy () =
  let cancelled = ref false in
  let cancel () = cancelled := true in
  let running = Timer.Timer_running (7, Some 11, cancel) in
  let inactive = Timer.Timer_inactive 7 in
  (match
     Timer.mark_failed ~advance_generation:succ ~effective_state:running
       ~current_state:running ~generation:7
   with
  | Some state ->
      Alcotest.(check string) "failed state" "inactive"
        (Timer.state_label state);
      Alcotest.(check int) "failed generation" 8
        (Timer.state_generation state);
      Alcotest.(check bool) "does not cancel running hook" false !cancelled
  | None -> Alcotest.fail "expected failed cleanup state");
  Alcotest.(check bool) "stale running ignored" true
    (Option.is_none
       (Timer.mark_failed ~advance_generation:succ ~effective_state:running
          ~current_state:running ~generation:8));
  Alcotest.(check bool) "inactive current ignored" true
    (Option.is_none
       (Timer.mark_failed ~advance_generation:succ ~effective_state:running
          ~current_state:inactive ~generation:7))

let test_daemon_cleanup_policy () =
  let cancelled = ref false in
  let cancel () = cancelled := true in
  let running = Timer.Timer_running (7, Some 11, cancel) in
  (match
     Timer.cleanup_after_exit ~advance_generation:succ
       ~effective_state:running ~current_state:running ~generation:7
       Timer.Daemon_ok
   with
  | Some state ->
      Alcotest.(check string) "ok stops" "inactive"
        (Timer.state_label state);
      Alcotest.(check int) "ok keeps generation" 7
        (Timer.state_generation state)
  | None -> Alcotest.fail "expected ok cleanup");
  (match
     Timer.cleanup_after_exit ~advance_generation:succ
       ~effective_state:running ~current_state:running ~generation:7
       Timer.Daemon_error
   with
  | Some state ->
      Alcotest.(check string) "error stops" "inactive"
        (Timer.state_label state);
      Alcotest.(check int) "error advances generation" 8
        (Timer.state_generation state);
      Alcotest.(check bool) "error does not cancel running hook" false
        !cancelled
  | None -> Alcotest.fail "expected error cleanup");
  Alcotest.(check bool) "successful failed-start noops" true
    (Option.is_none
       (Timer.cleanup_failed_start ~advance_generation:succ
          ~effective_state:running ~current_state:running ~generation:7
          Timer.Daemon_ok));
  Alcotest.(check bool) "failed start records failure" true
    (Option.is_some
       (Timer.cleanup_failed_start ~advance_generation:succ
          ~effective_state:running ~current_state:running ~generation:7
          Timer.Daemon_error))

let test_finish_current_daemon_policy () =
  let running = Timer.Timer_running (7, Some 11, noop) in
  let inactive = Timer.Timer_inactive 7 in
  (match
     Timer.finish_current_daemon ~advance_generation:succ
       ~effective_state:running ~current_state:running ~generation:7
   with
  | Some state ->
      Alcotest.(check string) "finished state" "finished"
        (Timer.state_label state);
      Alcotest.(check int) "active finish advances generation" 8
        (Timer.state_generation state)
  | None -> Alcotest.fail "expected current daemon finish");
  Alcotest.(check bool) "stale daemon ignored" true
    (Option.is_none
       (Timer.finish_current_daemon ~advance_generation:succ
          ~effective_state:running ~current_state:running ~generation:8));
  (match
     Timer.finish_current_daemon ~advance_generation:succ
       ~effective_state:running ~current_state:inactive ~generation:7
   with
  | Some state ->
      Alcotest.(check int) "uses current state generation" 7
        (Timer.state_generation state)
  | None -> Alcotest.fail "expected inactive current finish")

let test_read_next_due_policy () =
  let running_with_due = Timer.Timer_running (7, Some 11, noop) in
  let running_without_due = Timer.Timer_running_uncancellable (7, None) in
  let inactive = Timer.Timer_inactive 7 in
  Alcotest.(check (option int)) "current due" (Some 11)
    (Timer.read_next_due running_with_due ~generation:7 ~fallback:20);
  Alcotest.(check (option int)) "current fallback" (Some 20)
    (Timer.read_next_due running_without_due ~generation:7 ~fallback:20);
  Alcotest.(check (option int)) "stale running stops" None
    (Timer.read_next_due running_with_due ~generation:8 ~fallback:20);
  Alcotest.(check (option int)) "inactive stops" None
    (Timer.read_next_due inactive ~generation:7 ~fallback:20)

let test_set_next_due_policy () =
  let running = Timer.Timer_running (7, Some 11, noop) in
  let inactive = Timer.Timer_inactive 7 in
  (match
     Timer.set_next_due ~effective_state:running ~current_state:running
       ~generation:7 ~next_due_ms:20
   with
  | Some state ->
      Alcotest.(check (option int)) "updated next due" (Some 20)
        (Timer.state_next_due state)
  | None -> Alcotest.fail "expected next due update");
  Alcotest.(check bool) "stale running stops" true
    (Option.is_none
       (Timer.set_next_due ~effective_state:running ~current_state:running
          ~generation:8 ~next_due_ms:20));
  (match
     Timer.set_next_due ~effective_state:running ~current_state:inactive
       ~generation:7 ~next_due_ms:20
   with
  | Some state ->
      Alcotest.(check string) "updates current state" "inactive"
        (Timer.state_label state)
  | None -> Alcotest.fail "expected current state update plan")

let test_advance_next_due_policy () =
  let running = Timer.Timer_running (7, Some 11, noop) in
  let running_without_due = Timer.Timer_running_uncancellable (7, None) in
  let inactive = Timer.Timer_inactive 7 in
  (match
     Timer.advance_next_due ~effective_state:running ~current_state:running
       ~generation:7 ~expected:11 ~next_due_ms:20
   with
  | Timer.Advance_next_due_update state ->
      Alcotest.(check (option int)) "advanced next due" (Some 20)
        (Timer.state_next_due state)
  | Timer.Advance_next_due_stop | Timer.Advance_next_due_stale ->
      Alcotest.fail "expected next due advance");
  (match
     Timer.advance_next_due ~effective_state:running ~current_state:running
       ~generation:7 ~expected:12 ~next_due_ms:20
   with
  | Timer.Advance_next_due_stale -> ()
  | Timer.Advance_next_due_stop | Timer.Advance_next_due_update _ ->
      Alcotest.fail "expected stale next due");
  (match
     Timer.advance_next_due ~effective_state:running_without_due
       ~current_state:running_without_due ~generation:7 ~expected:11
       ~next_due_ms:20
   with
  | Timer.Advance_next_due_stale -> ()
  | Timer.Advance_next_due_stop | Timer.Advance_next_due_update _ ->
      Alcotest.fail "expected missing due to be stale");
  (match
     Timer.advance_next_due ~effective_state:running ~current_state:running
       ~generation:8 ~expected:11 ~next_due_ms:20
   with
  | Timer.Advance_next_due_stop -> ()
  | Timer.Advance_next_due_stale | Timer.Advance_next_due_update _ ->
      Alcotest.fail "expected stale generation to stop");
  match
    Timer.advance_next_due ~effective_state:running ~current_state:inactive
      ~generation:7 ~expected:11 ~next_due_ms:20
  with
  | Timer.Advance_next_due_update state ->
      Alcotest.(check string) "updates current state" "inactive"
        (Timer.state_label state)
  | Timer.Advance_next_due_stop | Timer.Advance_next_due_stale ->
      Alcotest.fail "expected current state update action"

let test_stop_policy () =
  let cancelled = ref false in
  let cancel () = cancelled := true in
  let starting = Timer.Timer_starting 7 in
  let running_uncancellable =
    Timer.Timer_running_uncancellable (8, Some 10)
  in
  let running = Timer.Timer_running (8, Some 10, cancel) in
  let inactive = Timer.Timer_inactive 3 in
  (match
     Timer.stop ~advance_generation:succ ~cancel_running:true starting
   with
  | Some plan ->
      Alcotest.(check int) "starting stop generation" 8
        (Timer.state_generation plan.stop_state);
      Alcotest.(check int) "starting no cancel" 0
        (List.length plan.stop_cancel_hooks)
  | None -> Alcotest.fail "expected starting stop plan");
  (match
     Timer.stop ~advance_generation:succ ~cancel_running:true
       running_uncancellable
   with
  | Some plan ->
      Alcotest.(check int) "uncancellable stop generation" 9
        (Timer.state_generation plan.stop_state);
      Alcotest.(check int) "uncancellable no cancel" 0
        (List.length plan.stop_cancel_hooks)
  | None -> Alcotest.fail "expected uncancellable stop plan");
  (match Timer.stop ~advance_generation:succ ~cancel_running:true running with
  | Some plan ->
      Alcotest.(check int) "running stop generation" 9
        (Timer.state_generation plan.stop_state);
      Alcotest.(check int) "running cancel" 1
        (List.length plan.stop_cancel_hooks);
      List.iter (fun hook -> hook ()) plan.stop_cancel_hooks;
      Alcotest.(check bool) "cancelled" true !cancelled
  | None -> Alcotest.fail "expected running stop plan");
  cancelled := false;
  (match Timer.stop ~advance_generation:succ ~cancel_running:false running with
  | Some plan ->
      Alcotest.(check int) "suppressed cancel" 0
        (List.length plan.stop_cancel_hooks);
      Alcotest.(check bool) "not cancelled" false !cancelled
  | None -> Alcotest.fail "expected running stop plan");
  Alcotest.(check bool) "inactive no plan" true
    (Option.is_none
       (Timer.stop ~advance_generation:succ ~cancel_running:true inactive))

let test_refresh_plans () =
  let running = Timer.Timer_running_uncancellable (1, Some 50) in
  let current = Timer.current_time_refresh_plan ~now_ms:85 in
  let current_from_spec =
    Timer.refresh_plan_for_spec ~state:running ~current_value:0
      ~now_ms:85 Timer.Refresh_current_time
  in
  Alcotest.(check (option int)) "current value" (Some 85)
    current.refresh_value;
  Alcotest.(check (option int)) "current spec value" current.refresh_value
    current_from_spec.refresh_value;
  Alcotest.(check (option int)) "current next due" None
    current.refresh_next_due_ms;
  Alcotest.(check bool) "current does not finish" false
    current.refresh_finish;
  let interval =
    Timer.interval_refresh_plan ~state:running ~interval_ms:10
      ~current_value:3 ~now_ms:85
  in
  Alcotest.(check (option int)) "interval value" (Some 7)
    interval.refresh_value;
  Alcotest.(check (option int)) "interval due" (Some 90)
    interval.refresh_next_due_ms;
  Alcotest.(check bool) "interval finish" false interval.refresh_finish;
  let interval_from_spec =
    Timer.refresh_plan_for_spec ~state:running ~current_value:3
      ~now_ms:85 (Timer.Refresh_interval 10)
  in
  Alcotest.(check (option int)) "interval spec value"
    interval.refresh_value interval_from_spec.refresh_value;
  Alcotest.(check (option int)) "interval spec due"
    interval.refresh_next_due_ms interval_from_spec.refresh_next_due_ms;
  let saturated =
    Timer.interval_refresh_plan
      ~state:(Timer.Timer_running_uncancellable (1, Some max_int))
      ~interval_ms:10 ~current_value:3 ~now_ms:max_int
  in
  Alcotest.(check bool) "saturated interval finishes" true
    saturated.refresh_finish;
  let deadline = Timer.deadline_refresh_plan ~now_ms:100 ~deadline_ms:99 in
  Alcotest.(check (option bool)) "deadline value" (Some true)
    deadline.refresh_value;
  Alcotest.(check bool) "deadline finish" true deadline.refresh_finish;
  let deadline_from_spec =
    Timer.refresh_plan_for_spec ~state:running ~current_value:false
      ~now_ms:100 (Timer.Refresh_deadline 99)
  in
  Alcotest.(check (option bool)) "deadline spec value"
    deadline.refresh_value deadline_from_spec.refresh_value;
  Alcotest.(check bool) "deadline spec finish" deadline.refresh_finish
    deadline_from_spec.refresh_finish

let test_refresh_transitions () =
  let transition_labels =
    List.map (function
      | Timer.Refresh_advance_due next_due_ms ->
          "advance:" ^ string_of_int next_due_ms
      | Timer.Refresh_set value -> "set:" ^ string_of_int value
      | Timer.Refresh_finish -> "finish")
  in
  Alcotest.(check (list string))
    "set only"
    [ "set:85" ]
    (transition_labels
       (Timer.refresh_transitions
          (Timer.current_time_refresh_plan ~now_ms:85)));
  Alcotest.(check (list string))
    "advance set finish order"
    [ "advance:90"; "set:7"; "finish" ]
    (transition_labels
       (Timer.refresh_transitions
          {
            Timer.refresh_value = Some 7;
            refresh_next_due_ms = Some 90;
            refresh_finish = true;
          }));
  Alcotest.(check (list string))
    "empty"
    []
    (transition_labels
       (Timer.refresh_transitions
          {
            Timer.refresh_value = None;
            refresh_next_due_ms = None;
            refresh_finish = false;
          }))

let test_finish_policy () =
  let cancelled = ref false in
  let cancel () = cancelled := true in
  let running = Timer.Timer_running (7, Some 10, cancel) in
  let inactive = Timer.Timer_inactive 3 in
  let running_plan = Timer.finish ~advance_generation:succ running in
  let inactive_plan = Timer.finish ~advance_generation:succ inactive in
  Alcotest.(check int) "active advances generation" 8
    (Timer.state_generation running_plan.finish_state);
  Alcotest.(check int) "inactive keeps generation" 3
    (Timer.state_generation inactive_plan.finish_state);
  Alcotest.(check int) "hook count" 1
    (List.length running_plan.finish_cancel_hooks);
  List.iter (fun hook -> hook ()) running_plan.finish_cancel_hooks;
  Alcotest.(check bool) "cancelled" true !cancelled

let () =
  Alcotest.run "eta_signal_timer"
    [
      ( "timer",
        [
          Alcotest.test_case "capped arithmetic" `Quick test_capped_arithmetic;
          Alcotest.test_case "due arithmetic" `Quick test_due_arithmetic;
          Alcotest.test_case "deadline arithmetic" `Quick
            test_deadline_arithmetic;
          Alcotest.test_case "validation policy" `Quick
            test_validation_policy;
          Alcotest.test_case "catch up policy" `Quick test_catch_up_policy;
          Alcotest.test_case "update batch policy" `Quick
            test_update_batch_policy;
          Alcotest.test_case "daemon wake plan" `Quick
            test_daemon_wake_plan;
          Alcotest.test_case "state helpers" `Quick test_state_helpers;
          Alcotest.test_case "debug snapshot" `Quick test_debug_snapshot;
          Alcotest.test_case "snapshot policy" `Quick test_snapshot_policy;
          Alcotest.test_case "refresh context" `Quick test_refresh_context;
          Alcotest.test_case "daemon status policy" `Quick
            test_daemon_status_policy;
          Alcotest.test_case "start and refresh policy" `Quick
            test_start_and_refresh_policy;
          Alcotest.test_case "demand policy" `Quick test_demand_policy;
          Alcotest.test_case "start policy" `Quick test_start_policy;
          Alcotest.test_case "begin start policy" `Quick
            test_begin_start_policy;
          Alcotest.test_case "install cancel policy" `Quick
            test_install_cancel_policy;
          Alcotest.test_case "mark stopped policy" `Quick
            test_mark_stopped_policy;
          Alcotest.test_case "mark failed policy" `Quick
            test_mark_failed_policy;
          Alcotest.test_case "daemon cleanup policy" `Quick
            test_daemon_cleanup_policy;
          Alcotest.test_case "finish current daemon policy" `Quick
            test_finish_current_daemon_policy;
          Alcotest.test_case "read next due policy" `Quick
            test_read_next_due_policy;
          Alcotest.test_case "set next due policy" `Quick
            test_set_next_due_policy;
          Alcotest.test_case "advance next due policy" `Quick
            test_advance_next_due_policy;
          Alcotest.test_case "stop policy" `Quick test_stop_policy;
          Alcotest.test_case "refresh plans" `Quick test_refresh_plans;
          Alcotest.test_case "refresh transitions" `Quick
            test_refresh_transitions;
          Alcotest.test_case "finish policy" `Quick test_finish_policy;
        ] );
    ]
