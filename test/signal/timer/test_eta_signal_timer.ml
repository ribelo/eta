module Timer = Eta_signal_timer

let pp_deadline_error ppf = function
  | `Past_deadline -> Format.pp_print_string ppf "Past_deadline"
  | `Deadline_overflow -> Format.pp_print_string ppf "Deadline_overflow"

let deadline_error =
  Alcotest.testable pp_deadline_error (fun left right -> left = right)

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
      List.iter (fun hook -> hook ()) (Timer.finish_cancel_hooks state);
      Alcotest.(check bool) "new cancel installed" true !new_cancelled
  | None -> Alcotest.fail "expected cancel install");
  new_cancelled := false;
  (match Timer.install_cancel running ~generation:7 ~cancel:new_cancel with
  | Some state ->
      Alcotest.(check (option int)) "running next due" (Some 11)
        (Timer.state_next_due state);
      List.iter (fun hook -> hook ()) (Timer.finish_cancel_hooks state);
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
  let due = Timer.due_refresh running ~interval_ms:10 ~now_ms:85 in
  Alcotest.(check int) "missed" 4 due.missed;
  Alcotest.(check (option int)) "next due" (Some 90) due.next_due_ms;
  Alcotest.(check bool) "not saturated" false due.saturated_due;
  let interval =
    Timer.interval_refresh ~state:running ~interval_ms:10 ~current_value:3
      ~now_ms:85
  in
  Alcotest.(check (option int)) "interval value" (Some 7)
    interval.interval_value;
  Alcotest.(check (option int)) "interval due" (Some 90)
    interval.interval_next_due_ms;
  Alcotest.(check bool) "interval finish" false interval.interval_finish;
  let deadline = Timer.deadline_refresh ~now_ms:100 ~deadline_ms:99 in
  Alcotest.(check bool) "deadline value" true deadline.deadline_value;
  Alcotest.(check bool) "deadline finish" true deadline.deadline_finish

let test_finish_policy () =
  let cancelled = ref false in
  let cancel () = cancelled := true in
  let running = Timer.Timer_running (7, Some 10, cancel) in
  let inactive = Timer.Timer_inactive 3 in
  Alcotest.(check int) "active advances generation" 8
    (Timer.state_generation
       (Timer.finish_state ~advance_generation:succ running));
  Alcotest.(check int) "inactive keeps generation" 3
    (Timer.state_generation
       (Timer.finish_state ~advance_generation:succ inactive));
  let hooks = Timer.finish_cancel_hooks running in
  Alcotest.(check int) "hook count" 1 (List.length hooks);
  List.iter (fun hook -> hook ()) hooks;
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
          Alcotest.test_case "catch up policy" `Quick test_catch_up_policy;
          Alcotest.test_case "state helpers" `Quick test_state_helpers;
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
          Alcotest.test_case "read next due policy" `Quick
            test_read_next_due_policy;
          Alcotest.test_case "set next due policy" `Quick
            test_set_next_due_policy;
          Alcotest.test_case "advance next due policy" `Quick
            test_advance_next_due_policy;
          Alcotest.test_case "stop policy" `Quick test_stop_policy;
          Alcotest.test_case "refresh plans" `Quick test_refresh_plans;
          Alcotest.test_case "finish policy" `Quick test_finish_policy;
        ] );
    ]
