module Timer_policy = Eta_signal_timer_policy

let pp_deadline_error ppf = function
  | `Past_deadline -> Format.pp_print_string ppf "Past_deadline"
  | `Deadline_overflow -> Format.pp_print_string ppf "Deadline_overflow"

let deadline_error =
  Alcotest.testable pp_deadline_error (fun left right -> left = right)

let pp_timer_error ppf = function
  | `Invalid_interval -> Format.pp_print_string ppf "Invalid_interval"

let timer_error =
  Alcotest.testable pp_timer_error (fun left right -> left = right)

let pp_runtime_error ppf = function
  | `Runtime_mismatch -> Format.pp_print_string ppf "Runtime_mismatch"

let runtime_error =
  Alcotest.testable pp_runtime_error (fun left right -> left = right)

let finish_plan_state plan =
  Timer_policy.finish_plan_result plan ~plan:(fun ~state ~cancel_hooks:_ ->
      state)

let finish_plan_cancel_hooks plan =
  Timer_policy.finish_plan_result plan ~plan:(fun ~state:_ ~cancel_hooks ->
      cancel_hooks)

let finish_plan_label plan =
  Timer_policy.finish_plan_result plan ~plan:(fun ~state ~cancel_hooks ->
      "finish:"
      ^ Timer_policy.state_label state
      ^ ":"
      ^ string_of_int (Timer_policy.state_generation state)
      ^ ":"
      ^ string_of_int (List.length cancel_hooks))

let stop_plan_state plan =
  Timer_policy.stop_plan_result plan ~plan:(fun ~state ~cancel_hooks:_ ->
      state)

let stop_plan_cancel_hooks plan =
  Timer_policy.stop_plan_result plan ~plan:(fun ~state:_ ~cancel_hooks ->
      cancel_hooks)

let stop_plan_label plan =
  Timer_policy.stop_plan_result plan ~plan:(fun ~state ~cancel_hooks ->
      "stop:"
      ^ string_of_int (Timer_policy.state_generation state)
      ^ ":"
      ^ string_of_int (List.length cancel_hooks))

let start_plan_state plan =
  Timer_policy.start_plan_result plan ~plan:(fun ~state ~generation:_ ->
      state)

let start_plan_generation plan =
  Timer_policy.start_plan_result plan ~plan:(fun ~state:_ ~generation ->
      generation)

let start_plan_label plan =
  Timer_policy.start_plan_result plan ~plan:(fun ~state ~generation ->
      "start:" ^ string_of_int generation ^ ":"
      ^ Timer_policy.state_label state)

let refresh_plan_value plan =
  Timer_policy.refresh_plan_result plan
    ~plan:(fun ~value ~next_due_ms:_ ~finish:_ -> value)

let refresh_plan_next_due_ms plan =
  Timer_policy.refresh_plan_result plan
    ~plan:(fun ~value:_ ~next_due_ms ~finish:_ -> next_due_ms)

let refresh_plan_finish plan =
  Timer_policy.refresh_plan_result plan
    ~plan:(fun ~value:_ ~next_due_ms:_ ~finish -> finish)

let update_batch_values batch =
  Timer_policy.update_batch_result batch
    ~plan:(fun ~count ~remaining ~yield -> (count, remaining, yield))

let wake_plan_values wake =
  Timer_policy.wake_plan_result wake
    ~plan:(fun ~next_due_ms ~saturated_due ~update_count ~update_missed ->
      (next_due_ms, saturated_due, update_count, update_missed))

let pp_wake_plan_values ppf
    (next_due_ms, saturated_due, update_count, update_missed) =
  Format.fprintf ppf "(%d,%b,%d,%d)" next_due_ms saturated_due
    update_count update_missed

let wake_plan_values_test =
  Alcotest.testable pp_wake_plan_values (fun left right -> left = right)

let debug_snapshot_label snapshot =
  Timer_policy.debug_snapshot_result snapshot
    ~plan:(fun ~state_label ~active ~running_generation ~has_cancel
               ~finished ~generation ->
      String.concat ":"
        [
          state_label;
          string_of_bool active;
          (match running_generation with
          | None -> "none"
          | Some generation -> string_of_int generation);
          string_of_bool has_cancel;
          string_of_bool finished;
          string_of_int generation;
        ])

let test_capped_arithmetic () =
  Alcotest.(check int) "add ignores negative" 10 (Timer_policy.add_ms_capped 10 (-2));
  Alcotest.(check int) "add caps" max_int (Timer_policy.add_ms_capped max_int 1);
  Alcotest.(check int) "mul zero" 0 (Timer_policy.mul_ms_capped 10 0);
  Alcotest.(check int) "mul caps" max_int (Timer_policy.mul_ms_capped max_int 2);
  Alcotest.(check int) "int add caps" max_int (Timer_policy.add_int_capped max_int 1)

let test_due_arithmetic () =
  Alcotest.(check int) "not due" 0
    (Timer_policy.missed_cadences ~interval_ms:10 ~next_due_ms:50 ~now_ms:49);
  Alcotest.(check int) "exactly due" 1
    (Timer_policy.missed_cadences ~interval_ms:10 ~next_due_ms:50 ~now_ms:50);
  Alcotest.(check int) "missed multiple" 4
    (Timer_policy.missed_cadences ~interval_ms:10 ~next_due_ms:50 ~now_ms:85);
  Alcotest.(check int) "advance" 90 (Timer_policy.advance_due 50 10 4);
  Alcotest.(check int) "initial next due" 60
    (Timer_policy.initial_next_due_ms ~now_ms:50 ~interval_ms:10);
  Alcotest.(check int) "initial next due caps" max_int
    (Timer_policy.initial_next_due_ms ~now_ms:max_int ~interval_ms:10);
  Alcotest.(check int) "future sleep delay" 10
    (Timer_policy.sleep_delay_ms ~now_ms:50 ~next_due_ms:60);
  Alcotest.(check int) "due sleep delay" 0
    (Timer_policy.sleep_delay_ms ~now_ms:60 ~next_due_ms:60);
  Alcotest.(check int) "past sleep delay" 0
    (Timer_policy.sleep_delay_ms ~now_ms:70 ~next_due_ms:60);
  Alcotest.(check int) "sleep delay caps overflow" max_int
    (Timer_policy.sleep_delay_ms ~now_ms:min_int ~next_due_ms:0)

let test_deadline_arithmetic () =
  Alcotest.(check (result int deadline_error)) "positive" (Ok 15)
    (Timer_policy.add_relative_deadline 10 5);
  Alcotest.(check (result int deadline_error)) "past" (Error `Past_deadline)
    (Timer_policy.add_relative_deadline 10 0);
  Alcotest.(check (result int deadline_error)) "overflow"
    (Error `Deadline_overflow)
    (Timer_policy.add_relative_deadline max_int 1)

let test_validation_policy () =
  Alcotest.(check (result unit deadline_error))
    "future deadline"
    (Ok ())
    (Timer_policy.validate_future_deadline ~now_ms:10 ~deadline_ms:11);
  Alcotest.(check (result unit deadline_error))
    "past deadline"
    (Error `Past_deadline)
    (Timer_policy.validate_future_deadline ~now_ms:10 ~deadline_ms:10);
  Alcotest.(check (result unit deadline_error))
    "positive duration"
    (Ok ())
    (Timer_policy.validate_positive_duration_ms 1);
  Alcotest.(check (result unit deadline_error))
    "non-positive duration"
    (Error `Past_deadline)
    (Timer_policy.validate_positive_duration_ms 0);
  Alcotest.(check (result unit timer_error))
    "positive interval"
    (Ok ())
    (Timer_policy.validate_interval_ms 1);
  Alcotest.(check (result unit timer_error))
    "non-positive interval"
    (Error `Invalid_interval)
    (Timer_policy.validate_interval_ms 0)

let test_runtime_validation_policy () =
  let calls = ref [] in
  let same_runtime expected actual =
    calls := (expected, actual) :: !calls;
    expected = actual
  in
  Alcotest.(check (result unit runtime_error))
    "matching runtime"
    (Ok ())
    (Timer_policy.validate_runtime ~same_runtime ~expected:1 ~actual:1);
  Alcotest.(check (list (pair int int)))
    "matching call"
    [ (1, 1) ] !calls;
  calls := [];
  Alcotest.(check (result unit runtime_error))
    "mismatched runtime"
    (Error `Runtime_mismatch)
    (Timer_policy.validate_runtime ~same_runtime ~expected:1 ~actual:2);
  Alcotest.(check (list (pair int int)))
    "mismatched call"
    [ (1, 2) ] !calls

let catch_up_policy_label = function
  | Timer_policy.Catch_up_every_cadence -> "every"
  | Timer_policy.Catch_up_once_per_wake -> "once"
  | Timer_policy.Catch_up_coalesced -> "coalesced"

let refresh_spec_label : type a. a Timer_policy.refresh_spec option -> string =
  function
  | None -> "none"
  | Some Timer_policy.Refresh_current_time -> "current_time"
  | Some (Timer_policy.Refresh_deadline deadline_ms) ->
      "deadline:" ^ string_of_int deadline_ms
  | Some (Timer_policy.Refresh_interval interval_ms) ->
      "interval:" ^ string_of_int interval_ms

let source_policy_label policy =
  Timer_policy.source_policy_result policy
    ~plan:
      (fun ~update_on_start ~catch_up_policy ~refresh_when_inactive
           ~refresh_on_demand ->
        String.concat ":"
          [
            string_of_bool update_on_start;
            catch_up_policy_label catch_up_policy;
            string_of_bool refresh_when_inactive;
            refresh_spec_label refresh_on_demand;
          ])

let test_source_policy_defaults () =
  Alcotest.(check string)
    "now policy" "true:once:true:current_time"
    (source_policy_label (Timer_policy.current_time_source_policy ()));
  Alcotest.(check string)
    "deadline policy" "true:once:true:deadline:100"
    (source_policy_label (Timer_policy.deadline_source_policy ~deadline_ms:100));
  Alcotest.(check string)
    "interval policy" "false:coalesced:false:interval:10"
    (source_policy_label (Timer_policy.interval_source_policy ~interval_ms:10));
  Alcotest.(check string)
    "step policy" "false:coalesced:false:none"
    (source_policy_label (Timer_policy.step_source_policy ()));
  Alcotest.(check string)
    "step replay policy" "false:every:false:none"
    (source_policy_label (Timer_policy.step_replay_source_policy ()))

let test_catch_up_policy () =
  Alcotest.(check int) "every count" 3
    (Timer_policy.catch_up_update_count Catch_up_every_cadence 3);
  Alcotest.(check int) "once count" 1
    (Timer_policy.catch_up_update_count Catch_up_once_per_wake 3);
  Alcotest.(check int) "coalesced count" 1
    (Timer_policy.catch_up_update_count Catch_up_coalesced 3);
  Alcotest.(check int) "every missed" 1
    (Timer_policy.catch_up_update_missed Catch_up_every_cadence 3);
  Alcotest.(check int) "coalesced missed" 3
    (Timer_policy.catch_up_update_missed Catch_up_coalesced 3)

let test_update_batch_policy () =
  Alcotest.(check bool) "no remaining work" true
    (Option.is_none (Timer_policy.update_batch ~remaining:0));
  (match Timer_policy.update_batch ~remaining:3 with
  | Some batch ->
      Alcotest.(check (triple int int bool))
        "small batch" (3, 0, false)
        (update_batch_values batch)
  | None -> Alcotest.fail "expected small batch");
  (match Timer_policy.update_batch ~remaining:65 with
  | Some batch ->
      Alcotest.(check (triple int int bool))
        "large batch" (64, 1, true)
        (update_batch_values batch)
  | None -> Alcotest.fail "expected large batch")

let test_daemon_wake_plan () =
  let every =
    Timer_policy.daemon_wake_plan ~catch_up_policy:Catch_up_every_cadence
      ~interval_ms:10 ~next_due_ms:50 ~now_ms:85
  in
  Alcotest.(check wake_plan_values_test)
    "every wake" (90, false, 4, 1)
    (wake_plan_values every);
  let coalesced =
    Timer_policy.daemon_wake_plan ~catch_up_policy:Catch_up_coalesced
      ~interval_ms:10 ~next_due_ms:50 ~now_ms:85
  in
  Alcotest.(check wake_plan_values_test)
    "coalesced wake" (90, false, 1, 4)
    (wake_plan_values coalesced);
  let not_due =
    Timer_policy.daemon_wake_plan ~catch_up_policy:Catch_up_every_cadence
      ~interval_ms:10 ~next_due_ms:50 ~now_ms:49
  in
  Alcotest.(check wake_plan_values_test)
    "not due wake" (50, false, 0, 0)
    (wake_plan_values not_due);
  let saturated =
    Timer_policy.daemon_wake_plan ~catch_up_policy:Catch_up_once_per_wake
      ~interval_ms:10 ~next_due_ms:max_int ~now_ms:max_int
  in
  Alcotest.(check wake_plan_values_test)
    "saturated wake" (max_int, true, 1, 1)
    (wake_plan_values saturated)

let noop () = ()

let timer_inactive generation = Timer_policy.inactive_state ~generation
let timer_starting generation = Timer_policy.starting_state ~generation

let timer_running_uncancellable generation next_due_ms =
  Timer_policy.running_uncancellable_state ~generation ~next_due_ms

let timer_running generation next_due_ms cancel =
  Timer_policy.running_state ~generation ~next_due_ms ~cancel

let timer_finished generation = Timer_policy.finished_state ~generation

let test_state_helpers () =
  let running = timer_running 7 (Some 10) noop in
  Alcotest.(check int) "generation" 7 (Timer_policy.state_generation running);
  Alcotest.(check string) "label" "running" (Timer_policy.state_label running);
  Alcotest.(check bool) "starting" false (Timer_policy.state_starting running);
  Alcotest.(check bool) "starting state" true
    (Timer_policy.state_starting (timer_starting 7));
  Alcotest.(check bool) "active" true (Timer_policy.state_active running);
  Alcotest.(check bool) "finished" false (Timer_policy.state_finished running);
  Alcotest.(check bool) "has current start" true
    (Timer_policy.state_has_current_start running);
  Alcotest.(check (option int)) "running generation" (Some 7)
    (Timer_policy.state_running_generation running);
  Alcotest.(check bool) "has cancel" true (Timer_policy.state_has_cancel running);
  Alcotest.(check bool) "running current" true
    (Timer_policy.state_running_current running 7);
  Alcotest.(check (option int)) "next due" (Some 10)
    (Timer_policy.state_next_due running);
  Alcotest.(check (option int)) "updated next due" (Some 20)
    (Timer_policy.state_next_due (Timer_policy.state_set_next_due running (Some 20)));
  Alcotest.(check int) "with generation" 8
    (Timer_policy.state_generation (Timer_policy.state_with_generation running 8))

let test_debug_snapshot () =
  let running = timer_running 7 (Some 10) noop in
  let running_snapshot = Timer_policy.debug_snapshot running in
  Alcotest.(check string)
    "running snapshot" "running:true:7:true:false:7"
    (debug_snapshot_label running_snapshot);
  let finished_snapshot =
    Timer_policy.debug_snapshot (timer_finished 8)
  in
  Alcotest.(check string)
    "finished snapshot" "finished:false:none:false:true:8"
    (debug_snapshot_label finished_snapshot)

let test_snapshot_policy () =
  let initial = Timer_policy.initial_snapshot in
  Alcotest.(check string) "initial state" "inactive"
    (Timer_policy.state_label (Timer_policy.snapshot_state initial));
  Alcotest.(check int) "initial generation" 0
    (Timer_policy.state_generation (Timer_policy.snapshot_state initial));
  Alcotest.(check int) "initial refresh token" (-1)
    (Timer_policy.snapshot_on_demand_refresh_token initial);
  let running =
    Timer_policy.snapshot
      ~state:(timer_running 7 (Some 10) noop)
      ~on_demand_refresh_token:3
  in
  Alcotest.(check int) "snapshot generation" 9
    (Timer_policy.state_generation
       (Timer_policy.snapshot_state
          (Timer_policy.snapshot_with_generation running 9)));
  Alcotest.(check int) "snapshot token update" 4
    (Timer_policy.snapshot_on_demand_refresh_token
       (Timer_policy.snapshot_with_on_demand_refresh_token running 4));
  (match Timer_policy.snapshot_with_next_due running 20 with
  | Some snapshot ->
      Alcotest.(check (option int)) "snapshot due" (Some 20)
        (Timer_policy.state_next_due (Timer_policy.snapshot_state snapshot))
  | None -> Alcotest.fail "expected active timer snapshot update");
  Alcotest.(check bool) "inactive next due rejected" true
    (Option.is_none (Timer_policy.snapshot_with_next_due initial 20))

let test_refresh_context () =
  let calls = ref 0 in
  let current = ref 41 in
  let now_ms () =
    incr calls;
    !current
  in
  let context =
    Timer_policy.create_refresh_context ~token:7 ~runtime_contract:"runtime"
      ~now_ms
  in
  Alcotest.(check int) "token" 7 (Timer_policy.refresh_token context);
  Alcotest.(check string)
    "runtime"
    "runtime"
    (Timer_policy.refresh_runtime_contract context);
  current := 42;
  Alcotest.(check int) "first sample" 42
    (Timer_policy.refresh_sample_now_ms context);
  current := 100;
  Alcotest.(check int) "cached sample" 42
    (Timer_policy.refresh_sample_now_ms context);
  Alcotest.(check int) "sample calls" 1 !calls;
  Alcotest.(check (list int)) "initial dirty items" []
    (Timer_policy.refresh_dirty_items context);
  Timer_policy.set_refresh_dirty_items context [ 1; 2 ];
  Alcotest.(check (list int)) "set dirty items" [ 1; 2 ]
    (Timer_policy.refresh_dirty_items context);
  Timer_policy.clear_refresh_dirty_items context;
  Alcotest.(check (list int)) "cleared dirty items" []
    (Timer_policy.refresh_dirty_items context)

let test_daemon_status_policy () =
  let running = timer_running 7 (Some 10) noop in
  let running_uncancellable =
    timer_running_uncancellable 7 (Some 10)
  in
  let inactive = timer_inactive 7 in
  (match Timer_policy.daemon_status running ~generation:7 with
  | Timer_policy.Daemon_continue -> ()
  | Timer_policy.Daemon_stop -> Alcotest.fail "expected running daemon to continue");
  (match Timer_policy.daemon_status running_uncancellable ~generation:7 with
  | Timer_policy.Daemon_continue -> ()
  | Timer_policy.Daemon_stop ->
      Alcotest.fail "expected uncancellable daemon to continue");
  (match Timer_policy.daemon_status running ~generation:8 with
  | Timer_policy.Daemon_stop -> ()
  | Timer_policy.Daemon_continue -> Alcotest.fail "expected stale daemon to stop");
  match Timer_policy.daemon_status inactive ~generation:7 with
  | Timer_policy.Daemon_stop -> ()
  | Timer_policy.Daemon_continue -> Alcotest.fail "expected inactive daemon to stop"

let test_start_and_refresh_policy () =
  let inactive = timer_inactive 0 in
  let running = timer_running 1 (Some 10) noop in
  let running_uncancellable =
    timer_running_uncancellable 1 (Some 10)
  in
  let finished = timer_finished 1 in
  Alcotest.(check bool) "inactive needs start" true
    (Timer_policy.needs_start ~effective_state:inactive ~current_state:inactive);
  Alcotest.(check bool) "running with current start does not need start" false
    (Timer_policy.needs_start ~effective_state:running ~current_state:running);
  Alcotest.(check bool) "uncancellable effective with inactive current needs start"
    true
    (Timer_policy.needs_start ~effective_state:running_uncancellable
       ~current_state:inactive);
  Alcotest.(check bool) "finished does not need start" false
    (Timer_policy.needs_start ~effective_state:finished ~current_state:finished);
  Alcotest.(check bool) "eligible refresh" true
    (Timer_policy.can_refresh_on_demand ~refresh_operation:true ~current_token:0
       ~staged_token:(-1) ~token:1 ~refresh_when_inactive:false ~active:true
       ~finished:false);
  Alcotest.(check bool) "no operation" false
    (Timer_policy.can_refresh_on_demand ~refresh_operation:false ~current_token:0
       ~staged_token:(-1) ~token:1 ~refresh_when_inactive:true ~active:true
       ~finished:false);
  Alcotest.(check bool) "already refreshed" false
    (Timer_policy.can_refresh_on_demand ~refresh_operation:true ~current_token:1
       ~staged_token:(-1) ~token:1 ~refresh_when_inactive:true ~active:true
       ~finished:false);
  Alcotest.(check bool) "inactive without refresh permission" false
    (Timer_policy.can_refresh_on_demand ~refresh_operation:true ~current_token:0
       ~staged_token:(-1) ~token:1 ~refresh_when_inactive:false ~active:false
       ~finished:false)

let pp_demand_action ppf = function
  | Timer_policy.Demand_none -> Format.pp_print_string ppf "Demand_none"
  | Timer_policy.Demand_start -> Format.pp_print_string ppf "Demand_start"
  | Timer_policy.Demand_stop -> Format.pp_print_string ppf "Demand_stop"

let demand_action =
  Alcotest.testable pp_demand_action (fun left right -> left = right)

let test_demand_policy () =
  let inactive = timer_inactive 0 in
  let running = timer_running 1 (Some 10) noop in
  let running_uncancellable =
    timer_running_uncancellable 1 (Some 10)
  in
  let finished = timer_finished 1 in
  Alcotest.(check demand_action) "necessary inactive starts" Timer_policy.Demand_start
    (Timer_policy.demand_action ~necessary:true ~effective_state:inactive
       ~current_state:inactive);
  Alcotest.(check demand_action) "necessary running stays" Timer_policy.Demand_none
    (Timer_policy.demand_action ~necessary:true ~effective_state:running
       ~current_state:running);
  Alcotest.(check demand_action) "necessary finished stays" Timer_policy.Demand_none
    (Timer_policy.demand_action ~necessary:true ~effective_state:finished
       ~current_state:finished);
  Alcotest.(check demand_action) "unnecessary running stops" Timer_policy.Demand_stop
    (Timer_policy.demand_action ~necessary:false ~effective_state:running
       ~current_state:running);
  Alcotest.(check demand_action) "unnecessary uncancellable stops"
    Timer_policy.Demand_stop
    (Timer_policy.demand_action ~necessary:false
       ~effective_state:running_uncancellable ~current_state:inactive);
  Alcotest.(check demand_action) "unnecessary inactive stays" Timer_policy.Demand_none
    (Timer_policy.demand_action ~necessary:false ~effective_state:inactive
       ~current_state:inactive);
  Alcotest.(check bool) "running needs stop" true
    (Timer_policy.needs_stop ~effective_state:running);
  Alcotest.(check bool) "inactive does not need stop" false
    (Timer_policy.needs_stop ~effective_state:inactive)

let demand_plan_values plans =
  List.map
    (function
      | Timer_policy.Demand_plan_start (item, plan) ->
          (item, start_plan_label plan)
      | Timer_policy.Demand_plan_stop (item, None) -> (item, "stop:none")
      | Timer_policy.Demand_plan_stop (item, Some plan) ->
          (item, stop_plan_label plan))
    plans

let test_demand_plans_policy () =
  let inactive = timer_inactive 0 in
  let running = timer_running 1 (Some 10) noop in
  let running_uncancellable =
    timer_running_uncancellable 1 (Some 10)
  in
  let finished = timer_finished 1 in
  let plans =
    Timer_policy.demand_plans ~advance_generation:succ ~cancel_running:true
      [
        Timer_policy.demand_item ~item:"start" ~necessary:true
          ~effective_state:inactive ~current_state:inactive;
        Timer_policy.demand_item ~item:"keep-running" ~necessary:true
          ~effective_state:running ~current_state:running;
        Timer_policy.demand_item ~item:"stop" ~necessary:false
          ~effective_state:running ~current_state:running;
        Timer_policy.demand_item ~item:"staged-stop" ~necessary:false
          ~effective_state:running_uncancellable ~current_state:inactive;
        Timer_policy.demand_item ~item:"finished" ~necessary:true
          ~effective_state:finished ~current_state:finished;
      ]
    |> demand_plan_values
  in
  Alcotest.(check (list (pair string string)))
    "non-noop demand plans"
    [
      ("start", "start:1:starting");
      ("stop", "stop:2:1");
      ("staged-stop", "stop:none");
    ]
    plans

let test_apply_demand_plans_preserves_effect_order () =
  let start_plan generation =
    match
      Timer_policy.start
        ~advance_generation:(fun _ -> generation)
        ~effective_state:(timer_inactive 0)
        ~current_state:(timer_inactive 0)
    with
    | Some plan -> plan
    | None -> Alcotest.fail "expected synthetic start plan"
  in
  let stop_plan generation =
    match
      Timer_policy.stop
        ~advance_generation:(fun _ -> generation)
        ~cancel_running:false (timer_starting 0)
    with
    | Some plan -> plan
    | None -> Alcotest.fail "expected synthetic stop plan"
  in
  let effects =
    Timer_policy.apply_demand_plans
      ~start:(fun item plan ->
        item ^ ":start:" ^ string_of_int (start_plan_generation plan))
      ~stop:(fun item plan ->
        let generation =
          Timer_policy.state_generation (stop_plan_state plan)
        in
        [
          item ^ ":stop:" ^ string_of_int generation ^ ":first";
          item ^ ":stop:" ^ string_of_int generation ^ ":second";
        ])
      [
        Timer_policy.Demand_plan_start ("a", start_plan 1);
        Timer_policy.Demand_plan_stop ("b", Some (stop_plan 2));
        Timer_policy.Demand_plan_stop ("ignored", None);
        Timer_policy.Demand_plan_start ("c", start_plan 3);
        Timer_policy.Demand_plan_stop ("d", Some (stop_plan 4));
      ]
  in
  Timer_policy.demand_effects_result effects
    ~plan:(fun ~start_attempts ~cancel_hooks ->
      Alcotest.(check (list string))
        "start attempts"
        [ "a:start:1"; "c:start:3" ]
        start_attempts;
      Alcotest.(check (list string))
        "cancel hooks"
        [
          "b:stop:2:first";
          "b:stop:2:second";
          "d:stop:4:first";
          "d:stop:4:second";
        ]
        cancel_hooks)

let test_demand_effects_classifies_resources () =
  let inactive = timer_inactive 0 in
  let running = timer_running 1 (Some 10) noop in
  let state = function
    | "start" -> inactive
    | "stop" -> running
    | "idle" -> inactive
    | timer -> Alcotest.failf "unexpected timer %s" timer
  in
  let validated = ref [] in
  let resources =
    [
      Timer_policy.demand_resource ~id:1 "start";
      Timer_policy.demand_resource ~id:2 "stop";
      Timer_policy.demand_resource ~id:3 "idle";
    ]
  in
  let context =
    Timer_policy.demand_context
      ~necessary:(fun id -> id = 1)
      ~validate:
        (fun timer ->
          validated := timer :: !validated;
          Ok ())
      ~effective_state:state ~current_state:state
      ~start:
        (fun timer plan ->
          timer ^ ":start:"
          ^ string_of_int (start_plan_generation plan))
      ~stop:
        (fun timer plan ->
          if List.length (stop_plan_cancel_hooks plan) = 0 then []
          else [ timer ^ ":stop" ])
  in
  match
    Timer_policy.demand_effects ~advance_generation:succ
      ~cancel_running:true context resources
  with
  | Error _ -> Alcotest.fail "unexpected demand validation failure"
  | Ok effects ->
      Alcotest.(check (list string))
        "validated necessary timers" [ "start" ] !validated;
      Timer_policy.demand_effects_result effects
        ~plan:(fun ~start_attempts ~cancel_hooks ->
          Alcotest.(check (list string))
            "start attempts" [ "start:start:1" ] start_attempts;
          Alcotest.(check (list string))
            "cancel hooks" [ "stop:stop" ] cancel_hooks)

let test_demand_effects_validation_failure_short_circuits () =
  let started = ref false in
  let stopped = ref false in
  let validated = ref [] in
  let inactive = timer_inactive 0 in
  let context =
    Timer_policy.demand_context
      ~necessary:(fun _id -> true)
      ~validate:
        (fun timer ->
          validated := timer :: !validated;
          Error `Runtime_mismatch)
      ~effective_state:(fun _timer -> inactive)
      ~current_state:(fun _timer -> inactive)
      ~start:
        (fun _timer _plan ->
          started := true;
          "started")
      ~stop:
        (fun _timer _plan ->
          stopped := true;
          [ "stopped" ])
  in
  let resources =
    [
      Timer_policy.demand_resource ~id:1 "bad";
      Timer_policy.demand_resource ~id:2 "unreached";
    ]
  in
  Alcotest.(check (result reject runtime_error))
    "runtime validation failure"
    (Error `Runtime_mismatch)
    (Timer_policy.demand_effects ~advance_generation:succ
       ~cancel_running:true context resources);
  Alcotest.(check (list string)) "validated once" [ "bad" ] !validated;
  Alcotest.(check bool) "no start effects" false !started;
  Alcotest.(check bool) "no stop effects" false !stopped

let test_start_policy () =
  let inactive = timer_inactive 0 in
  let running = timer_running 1 (Some 10) noop in
  let running_uncancellable =
    timer_running_uncancellable 1 (Some 10)
  in
  let finished = timer_finished 1 in
  (match
     Timer_policy.start ~advance_generation:succ ~effective_state:inactive
       ~current_state:inactive
   with
  | Some plan ->
      Alcotest.(check int) "inactive start generation" 1
        (start_plan_generation plan);
      Alcotest.(check int) "inactive start state generation" 1
        (Timer_policy.state_generation (start_plan_state plan))
  | None -> Alcotest.fail "expected inactive start plan");
  (match
     Timer_policy.start ~advance_generation:succ ~effective_state:running
       ~current_state:running
   with
  | Some _ -> Alcotest.fail "expected running no-op"
  | None -> ());
  (match
     Timer_policy.start ~advance_generation:succ ~effective_state:finished
       ~current_state:finished
   with
  | Some _ -> Alcotest.fail "expected finished no-op"
  | None -> ());
  match
    Timer_policy.start ~advance_generation:succ
      ~effective_state:running_uncancellable ~current_state:inactive
  with
  | Some plan ->
      Alcotest.(check int) "staged effective start generation" 1
        (start_plan_generation plan)
  | None -> Alcotest.fail "expected staged effective start plan"

let record_generation calls generation =
  calls := generation :: !calls;
  generation + 1

let test_preflight_policy () =
  let calls = ref [] in
  let inactive = timer_inactive 0 in
  let inactive_current = timer_inactive 5 in
  let running = timer_running 3 (Some 10) noop in
  let staged_running =
    timer_running_uncancellable 9 (Some 10)
  in
  Timer_policy.preflight_start ~advance_generation:(record_generation calls)
    ~effective_state:inactive ~current_state:inactive;
  Alcotest.(check (list int)) "inactive start checks generation" [ 0 ]
    !calls;
  calls := [];
  Timer_policy.preflight_start ~advance_generation:(record_generation calls)
    ~effective_state:running ~current_state:running;
  Alcotest.(check (list int)) "running start noops" [] !calls;
  Timer_policy.preflight_stop ~advance_generation:(record_generation calls)
    ~effective_state:running ~current_state:running;
  Alcotest.(check (list int)) "running stop checks generation" [ 3 ]
    !calls;
  calls := [];
  Timer_policy.preflight_stop ~advance_generation:(record_generation calls)
    ~effective_state:staged_running ~current_state:inactive_current;
  Alcotest.(check (list int))
    "staged active stop checks current generation"
    [ 5 ] !calls;
  calls := [];
  Timer_policy.preflight_stop ~advance_generation:(record_generation calls)
    ~effective_state:inactive_current ~current_state:inactive_current;
  Alcotest.(check (list int)) "inactive stop noops" [] !calls

let test_begin_start_policy () =
  let starting = timer_starting 7 in
  let running = timer_running 7 (Some 10) noop in
  (match Timer_policy.begin_start starting ~generation:7 with
  | Some state ->
      Alcotest.(check string) "state" "running_uncancellable"
        (Timer_policy.state_label state);
      Alcotest.(check int) "generation" 7 (Timer_policy.state_generation state);
      Alcotest.(check (option int)) "next due" None
        (Timer_policy.state_next_due state)
  | None -> Alcotest.fail "expected matching start to continue");
  Alcotest.(check bool) "stale start stops" true
    (Option.is_none (Timer_policy.begin_start starting ~generation:8));
  Alcotest.(check bool) "running start stops" true
    (Option.is_none (Timer_policy.begin_start running ~generation:7))

let test_install_cancel_policy () =
  let old_cancelled = ref false in
  let new_cancelled = ref false in
  let old_cancel () = old_cancelled := true in
  let new_cancel () = new_cancelled := true in
  let uncancellable = timer_running_uncancellable 7 (Some 10) in
  let running = timer_running 7 (Some 11) old_cancel in
  let inactive = timer_inactive 7 in
  (match
     Timer_policy.install_cancel uncancellable ~generation:7 ~cancel:new_cancel
   with
  | Some state ->
      Alcotest.(check string) "uncancellable state" "running"
        (Timer_policy.state_label state);
      Alcotest.(check (option int)) "uncancellable next due" (Some 10)
        (Timer_policy.state_next_due state);
      List.iter
        (fun hook -> hook ())
        (finish_plan_cancel_hooks
           (Timer_policy.finish ~advance_generation:succ state));
      Alcotest.(check bool) "new cancel installed" true !new_cancelled
  | None -> Alcotest.fail "expected cancel install");
  new_cancelled := false;
  (match Timer_policy.install_cancel running ~generation:7 ~cancel:new_cancel with
  | Some state ->
      Alcotest.(check (option int)) "running next due" (Some 11)
        (Timer_policy.state_next_due state);
      List.iter
        (fun hook -> hook ())
        (finish_plan_cancel_hooks
           (Timer_policy.finish ~advance_generation:succ state));
      Alcotest.(check bool) "old cancel replaced" false !old_cancelled;
      Alcotest.(check bool) "new cancel replacement" true !new_cancelled
  | None -> Alcotest.fail "expected cancel replacement");
  Alcotest.(check bool) "stale generation ignored" true
    (Option.is_none
       (Timer_policy.install_cancel running ~generation:8 ~cancel:new_cancel));
  Alcotest.(check bool) "inactive ignored" true
    (Option.is_none
       (Timer_policy.install_cancel inactive ~generation:7 ~cancel:new_cancel))

let test_mark_stopped_policy () =
  let running_uncancellable =
    timer_running_uncancellable 7 (Some 10)
  in
  let running = timer_running 7 (Some 11) noop in
  let inactive = timer_inactive 7 in
  (match Timer_policy.mark_stopped running_uncancellable ~generation:7 with
  | Some state ->
      Alcotest.(check string) "uncancellable stopped" "inactive"
        (Timer_policy.state_label state);
      Alcotest.(check int) "uncancellable generation" 7
        (Timer_policy.state_generation state)
  | None -> Alcotest.fail "expected uncancellable stopped state");
  (match Timer_policy.mark_stopped running ~generation:7 with
  | Some state ->
      Alcotest.(check string) "running stopped" "inactive"
        (Timer_policy.state_label state);
      Alcotest.(check int) "running generation" 7
        (Timer_policy.state_generation state)
  | None -> Alcotest.fail "expected running stopped state");
  Alcotest.(check bool) "stale running ignored" true
    (Option.is_none (Timer_policy.mark_stopped running ~generation:8));
  Alcotest.(check bool) "inactive ignored" true
    (Option.is_none (Timer_policy.mark_stopped inactive ~generation:7))

let test_mark_failed_policy () =
  let cancelled = ref false in
  let cancel () = cancelled := true in
  let running = timer_running 7 (Some 11) cancel in
  let inactive = timer_inactive 7 in
  (match
     Timer_policy.mark_failed ~advance_generation:succ ~effective_state:running
       ~current_state:running ~generation:7
   with
  | Some state ->
      Alcotest.(check string) "failed state" "inactive"
        (Timer_policy.state_label state);
      Alcotest.(check int) "failed generation" 8
        (Timer_policy.state_generation state);
      Alcotest.(check bool) "does not cancel running hook" false !cancelled
  | None -> Alcotest.fail "expected failed cleanup state");
  Alcotest.(check bool) "stale running ignored" true
    (Option.is_none
       (Timer_policy.mark_failed ~advance_generation:succ ~effective_state:running
          ~current_state:running ~generation:8));
  Alcotest.(check bool) "inactive current ignored" true
    (Option.is_none
       (Timer_policy.mark_failed ~advance_generation:succ ~effective_state:running
          ~current_state:inactive ~generation:7))

let test_daemon_cleanup_policy () =
  let cancelled = ref false in
  let cancel () = cancelled := true in
  let running = timer_running 7 (Some 11) cancel in
  (match
     Timer_policy.cleanup_after_exit ~advance_generation:succ
       ~effective_state:running ~current_state:running ~generation:7
       Timer_policy.Daemon_ok
   with
  | Some state ->
      Alcotest.(check string) "ok stops" "inactive"
        (Timer_policy.state_label state);
      Alcotest.(check int) "ok keeps generation" 7
        (Timer_policy.state_generation state)
  | None -> Alcotest.fail "expected ok cleanup");
  (match
     Timer_policy.cleanup_after_exit ~advance_generation:succ
       ~effective_state:running ~current_state:running ~generation:7
       Timer_policy.Daemon_error
   with
  | Some state ->
      Alcotest.(check string) "error stops" "inactive"
        (Timer_policy.state_label state);
      Alcotest.(check int) "error advances generation" 8
        (Timer_policy.state_generation state);
      Alcotest.(check bool) "error does not cancel running hook" false
        !cancelled
  | None -> Alcotest.fail "expected error cleanup");
  Alcotest.(check bool) "successful failed-start noops" true
    (Option.is_none
       (Timer_policy.cleanup_failed_start ~advance_generation:succ
          ~effective_state:running ~current_state:running ~generation:7
          Timer_policy.Daemon_ok));
  Alcotest.(check bool) "failed start records failure" true
    (Option.is_some
       (Timer_policy.cleanup_failed_start ~advance_generation:succ
          ~effective_state:running ~current_state:running ~generation:7
          Timer_policy.Daemon_error))

let test_finish_current_daemon_policy () =
  let running = timer_running 7 (Some 11) noop in
  let inactive = timer_inactive 7 in
  (match
     Timer_policy.finish_current_daemon ~advance_generation:succ
       ~effective_state:running ~current_state:running ~generation:7
   with
  | Some state ->
      Alcotest.(check string) "finished state" "finished"
        (Timer_policy.state_label state);
      Alcotest.(check int) "active finish advances generation" 8
        (Timer_policy.state_generation state)
  | None -> Alcotest.fail "expected current daemon finish");
  Alcotest.(check bool) "stale daemon ignored" true
    (Option.is_none
       (Timer_policy.finish_current_daemon ~advance_generation:succ
          ~effective_state:running ~current_state:running ~generation:8));
  (match
     Timer_policy.finish_current_daemon ~advance_generation:succ
       ~effective_state:running ~current_state:inactive ~generation:7
   with
  | Some state ->
      Alcotest.(check int) "uses current state generation" 7
        (Timer_policy.state_generation state)
  | None -> Alcotest.fail "expected inactive current finish")

let test_read_next_due_policy () =
  let running_with_due = timer_running 7 (Some 11) noop in
  let running_without_due = timer_running_uncancellable 7 None in
  let inactive = timer_inactive 7 in
  Alcotest.(check (option int)) "current due" (Some 11)
    (Timer_policy.read_next_due running_with_due ~generation:7 ~fallback:20);
  Alcotest.(check (option int)) "current fallback" (Some 20)
    (Timer_policy.read_next_due running_without_due ~generation:7 ~fallback:20);
  Alcotest.(check (option int)) "stale running stops" None
    (Timer_policy.read_next_due running_with_due ~generation:8 ~fallback:20);
  Alcotest.(check (option int)) "inactive stops" None
    (Timer_policy.read_next_due inactive ~generation:7 ~fallback:20)

let test_set_next_due_policy () =
  let running = timer_running 7 (Some 11) noop in
  let inactive = timer_inactive 7 in
  (match
     Timer_policy.set_next_due ~effective_state:running ~current_state:running
       ~generation:7 ~next_due_ms:20
   with
  | Some state ->
      Alcotest.(check (option int)) "updated next due" (Some 20)
        (Timer_policy.state_next_due state)
  | None -> Alcotest.fail "expected next due update");
  Alcotest.(check bool) "stale running stops" true
    (Option.is_none
       (Timer_policy.set_next_due ~effective_state:running ~current_state:running
          ~generation:8 ~next_due_ms:20));
  (match
     Timer_policy.set_next_due ~effective_state:running ~current_state:inactive
       ~generation:7 ~next_due_ms:20
   with
  | Some state ->
      Alcotest.(check string) "updates current state" "inactive"
        (Timer_policy.state_label state)
  | None -> Alcotest.fail "expected current state update plan")

let test_advance_next_due_policy () =
  let running = timer_running 7 (Some 11) noop in
  let running_without_due = timer_running_uncancellable 7 None in
  let inactive = timer_inactive 7 in
  (match
     Timer_policy.advance_next_due ~effective_state:running ~current_state:running
       ~generation:7 ~expected:11 ~next_due_ms:20
   with
  | Timer_policy.Advance_next_due_update state ->
      Alcotest.(check (option int)) "advanced next due" (Some 20)
        (Timer_policy.state_next_due state)
  | Timer_policy.Advance_next_due_stop | Timer_policy.Advance_next_due_stale ->
      Alcotest.fail "expected next due advance");
  (match
     Timer_policy.advance_next_due ~effective_state:running ~current_state:running
       ~generation:7 ~expected:12 ~next_due_ms:20
   with
  | Timer_policy.Advance_next_due_stale -> ()
  | Timer_policy.Advance_next_due_stop | Timer_policy.Advance_next_due_update _ ->
      Alcotest.fail "expected stale next due");
  (match
     Timer_policy.advance_next_due ~effective_state:running_without_due
       ~current_state:running_without_due ~generation:7 ~expected:11
       ~next_due_ms:20
   with
  | Timer_policy.Advance_next_due_stale -> ()
  | Timer_policy.Advance_next_due_stop | Timer_policy.Advance_next_due_update _ ->
      Alcotest.fail "expected missing due to be stale");
  (match
     Timer_policy.advance_next_due ~effective_state:running ~current_state:running
       ~generation:8 ~expected:11 ~next_due_ms:20
   with
  | Timer_policy.Advance_next_due_stop -> ()
  | Timer_policy.Advance_next_due_stale | Timer_policy.Advance_next_due_update _ ->
      Alcotest.fail "expected stale generation to stop");
  match
    Timer_policy.advance_next_due ~effective_state:running ~current_state:inactive
      ~generation:7 ~expected:11 ~next_due_ms:20
  with
  | Timer_policy.Advance_next_due_update state ->
      Alcotest.(check string) "updates current state" "inactive"
        (Timer_policy.state_label state)
  | Timer_policy.Advance_next_due_stop | Timer_policy.Advance_next_due_stale ->
      Alcotest.fail "expected current state update action"

let test_stop_policy () =
  let cancelled = ref false in
  let cancel () = cancelled := true in
  let starting = timer_starting 7 in
  let running_uncancellable =
    timer_running_uncancellable 8 (Some 10)
  in
  let running = timer_running 8 (Some 10) cancel in
  let inactive = timer_inactive 3 in
  (match
     Timer_policy.stop ~advance_generation:succ ~cancel_running:true starting
  with
  | Some plan ->
      Alcotest.(check int) "starting stop generation" 8
        (Timer_policy.state_generation (stop_plan_state plan));
      Alcotest.(check int) "starting no cancel" 0
        (List.length (stop_plan_cancel_hooks plan))
  | None -> Alcotest.fail "expected starting stop plan");
  (match
     Timer_policy.stop ~advance_generation:succ ~cancel_running:true
       running_uncancellable
  with
  | Some plan ->
      Alcotest.(check int) "uncancellable stop generation" 9
        (Timer_policy.state_generation (stop_plan_state plan));
      Alcotest.(check int) "uncancellable no cancel" 0
        (List.length (stop_plan_cancel_hooks plan))
  | None -> Alcotest.fail "expected uncancellable stop plan");
  (match Timer_policy.stop ~advance_generation:succ ~cancel_running:true running with
  | Some plan ->
      Alcotest.(check int) "running stop generation" 9
        (Timer_policy.state_generation (stop_plan_state plan));
      Alcotest.(check int) "running cancel" 1
        (List.length (stop_plan_cancel_hooks plan));
      List.iter (fun hook -> hook ()) (stop_plan_cancel_hooks plan);
      Alcotest.(check bool) "cancelled" true !cancelled
  | None -> Alcotest.fail "expected running stop plan");
  cancelled := false;
  (match Timer_policy.stop ~advance_generation:succ ~cancel_running:false running with
  | Some plan ->
      Alcotest.(check int) "suppressed cancel" 0
        (List.length (stop_plan_cancel_hooks plan));
      Alcotest.(check bool) "not cancelled" false !cancelled
  | None -> Alcotest.fail "expected running stop plan");
  Alcotest.(check bool) "inactive no plan" true
    (Option.is_none
       (Timer_policy.stop ~advance_generation:succ ~cancel_running:true inactive))

let test_refresh_plans () =
  let running = timer_running_uncancellable 1 (Some 50) in
  let current = Timer_policy.current_time_refresh_plan ~now_ms:85 in
  let current_from_spec =
    Timer_policy.refresh_plan_for_spec ~state:running ~current_value:0
      ~now_ms:85 Timer_policy.Refresh_current_time
  in
  Alcotest.(check (option int)) "current value" (Some 85)
    (refresh_plan_value current);
  Alcotest.(check (option int)) "current spec value"
    (refresh_plan_value current)
    (refresh_plan_value current_from_spec);
  Alcotest.(check (option int)) "current next due" None
    (refresh_plan_next_due_ms current);
  Alcotest.(check bool) "current does not finish" false
    (refresh_plan_finish current);
  let interval =
    Timer_policy.interval_refresh_plan ~state:running ~interval_ms:10
      ~current_value:3 ~now_ms:85
  in
  Alcotest.(check (option int)) "interval value" (Some 7)
    (refresh_plan_value interval);
  Alcotest.(check (option int)) "interval due" (Some 90)
    (refresh_plan_next_due_ms interval);
  Alcotest.(check bool) "interval finish" false
    (refresh_plan_finish interval);
  let interval_from_spec =
    Timer_policy.refresh_plan_for_spec ~state:running ~current_value:3
      ~now_ms:85 (Timer_policy.Refresh_interval 10)
  in
  Alcotest.(check (option int)) "interval spec value"
    (refresh_plan_value interval) (refresh_plan_value interval_from_spec);
  Alcotest.(check (option int)) "interval spec due"
    (refresh_plan_next_due_ms interval)
    (refresh_plan_next_due_ms interval_from_spec);
  let saturated =
    Timer_policy.interval_refresh_plan
      ~state:(timer_running_uncancellable 1 (Some max_int))
      ~interval_ms:10 ~current_value:3 ~now_ms:max_int
  in
  Alcotest.(check bool) "saturated interval finishes" true
    (refresh_plan_finish saturated);
  let deadline = Timer_policy.deadline_refresh_plan ~now_ms:100 ~deadline_ms:99 in
  Alcotest.(check (option bool)) "deadline value" (Some true)
    (refresh_plan_value deadline);
  Alcotest.(check bool) "deadline finish" true
    (refresh_plan_finish deadline);
  let deadline_from_spec =
    Timer_policy.refresh_plan_for_spec ~state:running ~current_value:false
      ~now_ms:100 (Timer_policy.Refresh_deadline 99)
  in
  Alcotest.(check (option bool)) "deadline spec value"
    (refresh_plan_value deadline) (refresh_plan_value deadline_from_spec);
  Alcotest.(check bool) "deadline spec finish"
    (refresh_plan_finish deadline)
    (refresh_plan_finish deadline_from_spec)

let test_refresh_actions () =
  let action_labels =
    List.map (function
      | Timer_policy.Refresh_advance_due next_due_ms ->
          "advance:" ^ string_of_int next_due_ms
      | Timer_policy.Refresh_set value -> "set:" ^ string_of_int value
      | Timer_policy.Refresh_finish plan ->
          finish_plan_label plan)
  in
  Alcotest.(check (list string))
    "set only"
    [ "set:85" ]
    (action_labels
       (Timer_policy.refresh_actions ~advance_generation:succ
          ~state:(timer_inactive 0)
          (Timer_policy.current_time_refresh_plan ~now_ms:85)));
  let cancelled = ref false in
  let running =
    timer_running 7 (Some 80) (fun () -> cancelled := true)
  in
  let finish_actions =
    Timer_policy.refresh_actions ~advance_generation:succ ~state:running
      (Timer_policy.refresh_plan ~value:(Some 7) ~next_due_ms:(Some 90)
         ~finish:true)
  in
  Alcotest.(check (list string))
    "advance set finish order"
    [ "advance:90"; "set:7"; "finish:finished:8:1" ]
    (action_labels finish_actions);
  (match List.rev finish_actions with
  | Timer_policy.Refresh_finish plan :: _ ->
      List.iter (fun hook -> hook ()) (finish_plan_cancel_hooks plan)
  | _ -> Alcotest.fail "expected finish action");
  Alcotest.(check bool) "finish action carries cancel hook" true !cancelled;
  let spec_actions =
    Timer_policy.refresh_actions_for_spec ~advance_generation:succ ~state:running
      ~current_value:false ~now_ms:85 (Timer_policy.Refresh_deadline 80)
  in
  Alcotest.(check (list string))
    "spec action includes finish plan"
    [ "set:true"; "finish:finished:8:1" ]
    (List.map
       (function
         | Timer_policy.Refresh_advance_due next_due_ms ->
             "advance:" ^ string_of_int next_due_ms
         | Timer_policy.Refresh_set value -> "set:" ^ string_of_bool value
         | Timer_policy.Refresh_finish plan ->
             finish_plan_label plan)
       spec_actions);
  Alcotest.(check (list string))
    "empty"
    []
    (action_labels
       (Timer_policy.refresh_actions ~advance_generation:succ
          ~state:(timer_inactive 0)
          (Timer_policy.refresh_plan ~value:None ~next_due_ms:None
             ~finish:false)))

let test_finish_policy () =
  let cancelled = ref false in
  let cancel () = cancelled := true in
  let running = timer_running 7 (Some 10) cancel in
  let inactive = timer_inactive 3 in
  let running_plan = Timer_policy.finish ~advance_generation:succ running in
  let inactive_plan = Timer_policy.finish ~advance_generation:succ inactive in
  Alcotest.(check int) "active advances generation" 8
    (Timer_policy.state_generation (finish_plan_state running_plan));
  Alcotest.(check int) "inactive keeps generation" 3
    (Timer_policy.state_generation (finish_plan_state inactive_plan));
  Alcotest.(check int) "hook count" 1
    (List.length (finish_plan_cancel_hooks running_plan));
  List.iter (fun hook -> hook ()) (finish_plan_cancel_hooks running_plan);
  Alcotest.(check bool) "cancelled" true !cancelled

let () =
  Alcotest.run "eta_signal_timer_policy"
    [
      ( "timer",
        [
          Alcotest.test_case "capped arithmetic" `Quick test_capped_arithmetic;
          Alcotest.test_case "due arithmetic" `Quick test_due_arithmetic;
          Alcotest.test_case "deadline arithmetic" `Quick
            test_deadline_arithmetic;
          Alcotest.test_case "validation policy" `Quick
            test_validation_policy;
          Alcotest.test_case "runtime validation policy" `Quick
            test_runtime_validation_policy;
          Alcotest.test_case "source policy defaults" `Quick
            test_source_policy_defaults;
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
          Alcotest.test_case "demand plans policy" `Quick
            test_demand_plans_policy;
          Alcotest.test_case "apply demand plans preserves effect order" `Quick
            test_apply_demand_plans_preserves_effect_order;
          Alcotest.test_case "demand effects classification" `Quick
            test_demand_effects_classifies_resources;
          Alcotest.test_case "demand effects validation failure" `Quick
            test_demand_effects_validation_failure_short_circuits;
          Alcotest.test_case "start policy" `Quick test_start_policy;
          Alcotest.test_case "preflight policy" `Quick
            test_preflight_policy;
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
          Alcotest.test_case "refresh actions" `Quick
            test_refresh_actions;
          Alcotest.test_case "finish policy" `Quick test_finish_policy;
        ] );
    ]
