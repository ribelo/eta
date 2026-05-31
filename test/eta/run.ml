open Test_eta_mutable_ref
open Test_eta_effect_core
open Test_eta_effect_concurrency
open Test_eta_effect_retry_repeat
open Test_eta_effect_resource_timeout
open Test_eta_effect_uninterruptible
open Test_eta_island
open Test_eta_blocking
open Test_eta_supervisor
open Test_eta_clock_resource_scope
open Test_eta_duration_schedule
open Test_eta_portable_queue
open Test_eta_queue
open Test_eta_channel
open Test_eta_pubsub
open Test_eta_pool
open Test_eta_semaphore
open Test_eta_properties
open Test_eta_observability
open Test_eta_redacted
open Test_eta_stress

let () =
  Alcotest.run "eta"
    [
      ( "MutableRef",
        [
          Alcotest.test_case "make get" `Quick test_mutable_ref_make_get;
          Alcotest.test_case "set" `Quick test_mutable_ref_set;
          Alcotest.test_case "update" `Quick test_mutable_ref_update;
          Alcotest.test_case "update_and_get" `Quick
            test_mutable_ref_update_and_get;
          Alcotest.test_case "get_and_set" `Quick test_mutable_ref_get_and_set;
          Alcotest.test_case "compare_and_set" `Quick
            test_mutable_ref_compare_and_set;
          Alcotest.test_case "concurrent update" `Quick
            test_mutable_ref_concurrent_update;
          Alcotest.test_case "incr decr" `Quick test_mutable_ref_incr_decr;
        ] );
      ( "Effect",
        [
          Alcotest.test_case "Pure" `Quick test_pure;
          Alcotest.test_case "Map" `Quick test_map;
          Alcotest.test_case "explicit dependency passing" `Quick
            test_explicit_dependency_passing;
          Alcotest.test_case "par returns pair" `Quick
            test_par_returns_both_successes;
          Alcotest.test_case "par keeps heterogeneous successes private" `Quick
            test_par_keeps_heterogeneous_successes_private;
          Alcotest.test_case "par fail-fast cancels sibling" `Quick
            test_par_fail_fast_cancels_sibling;
          Alcotest.test_case "all collects in input order" `Quick
            test_all_collects_in_input_order;
          Alcotest.test_case "all preserves delayed input order" `Quick
            test_all_preserves_input_order_with_out_of_order_completion;
          Alcotest.test_case "all empty returns empty list" `Quick
            test_all_empty_returns_empty_list;
          Alcotest.test_case "all fail-fast" `Quick test_all_fail_fast;
          Alcotest.test_case "all_settled collects outcomes" `Quick
            test_all_settled_collects_successes_and_failures;
          Alcotest.test_case "all_settled preserves delayed input order" `Quick
            test_all_settled_preserves_input_order_with_out_of_order_completion;
          Alcotest.test_case "all_settled runs all children" `Quick
            test_all_settled_runs_all_children;
          Alcotest.test_case "all_settled timeout scoped resource typed" `Quick
            test_all_settled_timeout_scoped_resource_is_typed;
          Alcotest.test_case "all_settled empty" `Quick test_all_settled_empty;
          Alcotest.test_case "for_each_par success" `Quick
            test_for_each_par_success;
          Alcotest.test_case "for_each_par preserves delayed input order" `Quick
            test_for_each_par_preserves_input_order_with_out_of_order_completion;
          Alcotest.test_case "for_each_par one fails" `Quick
            test_for_each_par_one_fails;
          Alcotest.test_case "for_each_par_bounded caps concurrency" `Quick
            test_for_each_par_bounded_caps_concurrency;
          Alcotest.test_case "for_each_par_bounded max one is sequential" `Quick
            test_for_each_par_bounded_max_one_is_sequential;
          Alcotest.test_case "for_each_par_bounded rejects nonpositive max"
            `Quick test_for_each_par_bounded_rejects_nonpositive_max;
          Alcotest.test_case "for_each_par_bounded fail-fast" `Quick
            test_for_each_par_bounded_fail_fast;
          Alcotest.test_case "collect_names" `Quick test_collect_names;
          Alcotest.test_case "map bind tap runtime" `Quick
            test_effect_map_bind_tap_runtime;
          Alcotest.test_case "catch success and failure" `Quick
            test_effect_catch_success_and_failure;
          Alcotest.test_case "catch handler failure uses outer key" `Quick
            test_effect_catch_handler_failure_uses_outer_key;
          Alcotest.test_case "from_result" `Quick test_effect_from_result;
          Alcotest.test_case "exit to_result faithful subset" `Quick
            test_exit_to_result_only_converts_success_and_single_typed_failure;
          Alcotest.test_case "map_error maps full cause" `Quick
            test_effect_map_error_maps_full_cause;
          Alcotest.test_case "map_error preserves defects" `Quick
            test_effect_map_error_preserves_defects_in_cause_tree;
          Alcotest.test_case "map_error preserves interrupts" `Quick
            test_effect_map_error_preserves_interrupts_in_cause_tree;
          Alcotest.test_case "scoped creates switch in fiberless host run"
            `Quick
            test_effect_scoped_creates_switch_in_fiberless_host_run;
          Alcotest.test_case "syntax operators" `Quick
            test_effect_syntax_operators;
          Alcotest.test_case "tap_error observes and rethrows" `Quick
            test_effect_tap_error_observes_and_rethrows;
          Alcotest.test_case "tap_error observer failure preserves typed failure"
            `Quick
            test_effect_tap_error_observer_failure_preserves_typed_failure;
          Alcotest.test_case "tap_error does not observe defects" `Quick
            test_effect_tap_error_does_not_observe_defects;
          Alcotest.test_case "finally success and failure" `Quick
            test_effect_finally_success_and_failure;
          Alcotest.test_case "finally cleanup failure after success" `Quick
            test_effect_finally_cleanup_failure_after_success;
          Alcotest.test_case "finally suppresses cleanup failure" `Quick
            test_effect_finally_suppresses_cleanup_failure;
          Alcotest.test_case "finally runs after defect" `Quick
            test_effect_finally_runs_after_defect;
          Alcotest.test_case
            "finally suppresses cleanup failure after defect" `Quick
            test_effect_finally_suppresses_cleanup_failure_after_defect;
          Alcotest.test_case "finally runs on cancellation" `Quick
            test_effect_finally_runs_on_cancellation;
          Alcotest.test_case "catch preserves suppressed finalizer failure" `Quick
            test_effect_catch_preserves_suppressed_finalizer_failure;
          Alcotest.test_case "empty cause aggregations reject" `Quick
            test_cause_empty_aggregations_reject;
          Alcotest.test_case "diagnostic cause equality" `Quick
            test_cause_diagnostic_equal_compares_die_payloads;
          Alcotest.test_case "runtime exit fail die interrupt" `Quick
            test_runtime_exit_fail_die_interrupt;
          Alcotest.test_case "die captures diagnostics" `Quick
            test_runtime_die_captures_diagnostics;
          Alcotest.test_case "portable cause materializes diagnostics" `Quick
            test_cause_to_portable_materializes_diagnostics;
          Alcotest.test_case "die backtrace capture flag" `Quick
            test_runtime_die_capture_backtrace_can_be_disabled;
          Alcotest.test_case "run_exn preserves backtrace" `Quick
            test_runtime_run_exn_uses_captured_backtrace;
          Alcotest.test_case "run_exn preserves typed failure diagnostics" `Quick
            test_runtime_run_exn_preserves_typed_failure_diagnostics;
          Alcotest.test_case "concurrent child die captures diagnostics" `Quick
            test_runtime_concurrent_child_die_captures_diagnostics;
          Alcotest.test_case "finalizer die captures diagnostics" `Quick
            test_runtime_finalizer_die_captures_diagnostics;
          Alcotest.test_case "catch does not catch interrupt" `Quick
            test_effect_catch_does_not_catch_interrupt;
          Alcotest.test_case "catch preserves finalizer defect" `Quick
            test_effect_catch_preserves_suppressed_finalizer_defect;
          Alcotest.test_case "catch preserves concurrent defect" `Quick
            test_effect_catch_preserves_concurrent_defect;
          Alcotest.test_case "catch preserves concurrent interrupt" `Quick
            test_effect_catch_preserves_concurrent_interrupt;
          Alcotest.test_case "catch unsound suppressed typed failure" `Quick
            test_effect_catch_unsound_suppressed_typed_failure;
          Alcotest.test_case "catch unsound concurrent typed failure" `Quick
            test_effect_catch_unsound_concurrent_typed_failure;
          Alcotest.test_case "acquire release" `Quick test_acquire_release;
          Alcotest.test_case "acquire release root finalizer" `Quick
            test_acquire_release_root_scope_runs_finalizer;
          Alcotest.test_case "acquire release root failure finalizer" `Quick
            test_acquire_release_root_scope_runs_finalizer_on_failure;
          Alcotest.test_case "daemon drains acquire release finalizer" `Quick
            test_daemon_drains_acquire_release_finalizer;
          Alcotest.test_case "drain does not busy wait" `Quick
            test_drain_does_not_busy_wait;
          Alcotest.test_case "daemon failure logs diagnostic" `Quick
            test_daemon_failure_logs_diagnostic;
          Alcotest.test_case "daemon interrupt stays quiet" `Quick
            test_daemon_interrupt_does_not_log_diagnostic;
          Alcotest.test_case "acquire release on failure" `Quick
            test_acquire_release_on_failure;
          Alcotest.test_case "acquire release suppresses release failure" `Quick
            test_acquire_release_suppresses_release_failure;
          Alcotest.test_case "acquire release release failure after success"
            `Quick test_acquire_release_release_failure_after_success;
          Alcotest.test_case "acquire release releases on defect" `Quick
            test_acquire_release_releases_on_defect;
          Alcotest.test_case
            "acquire release suppresses release failure after defect" `Quick
            test_acquire_release_suppresses_release_failure_after_defect;
          Alcotest.test_case "acquire_use_release success" `Quick
            test_acquire_use_release_success;
          Alcotest.test_case "acquire_use_release typed failure releases"
            `Quick test_acquire_use_release_typed_failure_releases;
          Alcotest.test_case "acquire_use_release defect releases" `Quick
            test_acquire_use_release_defect_releases;
          Alcotest.test_case
            "acquire_use_release suppresses release failure after defect" `Quick
            test_acquire_use_release_suppresses_release_failure_after_defect;
          Alcotest.test_case "acquire_use_release releases on cancel" `Quick
            test_acquire_use_release_releases_on_cancel;
          Alcotest.test_case
            "acquire_use_release release failure after success" `Quick
            test_acquire_use_release_release_failure_after_success;
          Alcotest.test_case "acquire release finalizers lifo sequential"
            `Quick test_acquire_release_finalizers_run_lifo_sequentially;
          Alcotest.test_case "acquire release finalizer failure keeps running"
            `Quick test_acquire_release_finalizer_failure_keeps_running_lifo;
          Alcotest.test_case "repeat releases resources each iteration" `Quick
            test_repeat_releases_resources_each_iteration;
          Alcotest.test_case "timeout uses virtual clock" `Quick
            test_effect_timeout_uses_virtual_clock;
          Alcotest.test_case "timeout allows fast success" `Quick
            test_effect_timeout_allows_fast_success;
          Alcotest.test_case "timeout preserves user timeout failure" `Quick
            test_effect_timeout_preserves_user_timeout_failure;
          Alcotest.test_case "nested timeout maps outer timeout" `Quick
            test_effect_timeout_nested_cancel_maps_to_outer_timeout;
          Alcotest.test_case "timeout_as exact error row" `Quick
            test_effect_timeout_as_keeps_exact_error_row;
          Alcotest.test_case "timeout_as maps delayed effect" `Quick
            test_effect_timeout_as_maps_delayed_effect;
          Alcotest.test_case "timeout_as preserves simultaneous failure" `Quick
            test_effect_timeout_as_preserves_simultaneous_body_failure;
          Alcotest.test_case "timeout_as nested maps outer timeout" `Quick
            test_effect_timeout_as_nested_cancel_maps_to_outer_timeout;
          Alcotest.test_case "race ignores early failure until success" `Quick
            test_effect_race_ignores_early_failure_until_success;
          Alcotest.test_case "race cancels losers after first success" `Quick
            test_effect_race_cancels_losers_after_first_success;
          Alcotest.test_case "race all failures returns concurrent causes" `Quick
            test_effect_race_all_failures_returns_concurrent_causes;
          Alcotest.test_case "par simultaneous failures baseline" `Quick
            test_par_simultaneous_failures_records_concurrent_baseline;
          Alcotest.test_case "par finalizer cancellation baseline" `Quick
            test_par_finalizer_failure_during_sibling_cancellation;
          Alcotest.test_case "all finalizer cancellation baseline" `Quick
            test_all_finalizer_failure_during_sibling_cancellation_baseline;
          Alcotest.test_case "for_each_par simultaneous failures baseline" `Quick
            test_for_each_par_simultaneous_failures_baseline;
          Alcotest.test_case "for_each_par finalizer cancellation baseline"
            `Quick test_for_each_par_finalizer_failure_during_sibling_cancellation;
          Alcotest.test_case "par child finalizer before catch handler" `Quick
            test_par_child_finalizer_runs_before_catch_handler;
          Alcotest.test_case "all child finalizer before catch handler" `Quick
            test_all_child_finalizer_runs_before_catch_handler;
          Alcotest.test_case
            "for_each_par child finalizer before catch handler" `Quick
            test_for_each_par_child_finalizer_runs_before_catch_handler;
          Alcotest.test_case "par nested race failures baseline" `Quick
            test_par_nested_race_all_failures_baseline;
          Alcotest.test_case "retry does nothing on initial success" `Quick
            test_effect_retry_does_nothing_on_initial_success;
          Alcotest.test_case "retry stops when predicate rejects" `Quick
            test_effect_retry_stops_when_predicate_rejects_typed_error;
          Alcotest.test_case "retry recurs attempts initial plus retries" `Quick
            test_effect_retry_recurs_attempts_initial_plus_retries;
          Alcotest.test_case "retry does not catch defects" `Quick
            test_effect_retry_does_not_catch_defects;
          Alcotest.test_case "repeat schedule" `Quick test_effect_repeat_schedule;
          Alcotest.test_case "repeat recurs zero runs body once" `Quick
            test_effect_repeat_recurs_zero_runs_body_once;
          Alcotest.test_case "repeat schedule uses virtual delays" `Quick
            test_effect_repeat_schedule_uses_virtual_delays;
          Alcotest.test_case "repeat timeout interrupts loop" `Quick
            test_effect_repeat_timeout_interrupts_loop;
          Alcotest.test_case "retry schedule until success" `Quick
            test_effect_retry_schedule_until_success;
          Alcotest.test_case "retry schedule uses virtual delays" `Quick
            test_effect_retry_schedule_uses_virtual_delays;
          Alcotest.test_case "retry timeout interrupts loop" `Quick
            test_effect_retry_timeout_interrupts_loop;
          Alcotest.test_case "retry jittered schedule uses runtime random" `Quick
            test_effect_retry_jittered_schedule_uses_runtime_random;
          Alcotest.test_case "retry releases resources each failed attempt"
            `Quick
            test_effect_retry_releases_resources_each_failed_attempt;
          Alcotest.test_case "retry does not retry interrupt" `Quick
            test_effect_retry_does_not_retry_interrupt;
          Alcotest.test_case "retry preserves structured exception causes"
            `Quick
            test_effect_retry_preserves_structured_exception_causes;
          Alcotest.test_case "uninterruptible defers race cancellation" `Quick
            test_effect_uninterruptible_defers_race_cancellation;
          Alcotest.test_case "uninterruptible nested masks" `Quick
            test_uninterruptible_nested_masks_wait_for_protected_loser;
          Alcotest.test_case "uninterruptible blocking finalizer" `Quick
            test_uninterruptible_blocking_finalizer_delays_race_completion;
          Alcotest.test_case "uninterruptible timeout inside protected" `Quick
            test_uninterruptible_timeout_inside_protected_still_fires;
          Alcotest.test_case "uninterruptible no-checkpoint loser" `Quick
            test_uninterruptible_race_loser_without_checkpoints_returns;
        ] );
      ( "Island",
        [
          Alcotest.test_case "single uses runtime pool" `Quick
            test_island_single_uses_runtime_pool;
          Alcotest.test_case "requires pool" `Quick test_island_requires_pool;
          Alcotest.test_case "run pool override" `Quick
            test_island_run_pool_override;
          Alcotest.test_case "map preserves order" `Quick
            test_island_map_preserves_order;
          Alcotest.test_case "map uses pool fanout" `Quick
            test_island_map_uses_pool_fanout;
          Alcotest.test_case "map_result returns item results" `Quick
            test_island_map_result_returns_item_results;
          Alcotest.test_case "all_settled returns worker_died" `Quick
            test_island_all_settled_returns_worker_died;
          Alcotest.test_case "worker_died captures exception details" `Quick
            test_island_worker_died_captures_exception_details;
          Alcotest.test_case "map worker crash fails outer effect" `Quick
            test_island_map_worker_crash_fails_outer_effect;
          Alcotest.test_case "workloads" `Quick test_island_workloads;
        ] );
      ( "Blocking",
        [
          Alcotest.test_case "submit alias and stats" `Quick
            test_blocking_submit_alias_and_stats;
          Alcotest.test_case "blocking_result lifts result" `Quick
            test_blocking_result_lifts_result;
          Alcotest.test_case "blocking_result_timeout interrupts" `Quick
            test_blocking_result_timeout_interrupts_and_fails_typed;
          Alcotest.test_case "blocking_result_timeout cancels once" `Quick
            test_blocking_result_timeout_calls_on_cancel_once;
          Alcotest.test_case "custom runner" `Quick
            test_blocking_pool_custom_runner;
          Alcotest.test_case "runner cancellation releases started slot" `Quick
            test_blocking_runner_cancellation_releases_started_slot;
          Alcotest.test_case "direct control and heartbeat" `Quick
            test_blocking_direct_control_and_blocking_heartbeat;
          Alcotest.test_case "wait caps active and queue" `Quick
            test_blocking_wait_policy_caps_active_and_queue;
          Alcotest.test_case "reject deterministic" `Quick
            test_blocking_reject_policy_deterministic;
          Alcotest.test_case "pending cancellation" `Quick
            test_blocking_pending_cancellation_removes_queued_job;
          Alcotest.test_case "started cancellation nonpreemptive" `Quick
            test_blocking_started_cancellation_is_nonpreemptive;
          Alcotest.test_case "shutdown rejects new jobs" `Quick
            test_blocking_shutdown_rejects_new_jobs;
          Alcotest.test_case "shutdown drain waits" `Quick
            test_blocking_shutdown_drain_waits_for_started;
          Alcotest.test_case "shutdown detach records" `Quick
            test_blocking_shutdown_detach_started_returns_promptly;
          Alcotest.test_case "detach started counts each job once" `Quick
            test_blocking_detach_started_counts_each_job_once;
          Alcotest.test_case "named pools isolate" `Quick
            test_blocking_named_pools_prevent_starvation;
          Alcotest.test_case "domain isolated hold-lock" `Quick
            test_blocking_domain_isolated_preserves_hold_lock_heartbeat;
          Alcotest.test_case "worker rejects nested submit" `Quick
            test_blocking_worker_rejects_nested_submit;
          Alcotest.test_case "worker rejects runtime run" `Quick
            test_blocking_worker_rejects_runtime_run;
          Alcotest.test_case "cpu antipattern" `Quick
            test_blocking_cpu_antipattern_has_no_speedup;
          Alcotest.test_case "observability labels timings" `Quick
            test_blocking_observability_labels_and_timings;
          Alcotest.test_case "user Exit not swallowed as interrupt" `Quick
            test_blocking_user_exit_not_swallowed_as_interrupt;
          Alcotest.test_case "eio cancellation preserves Cancelled identity" `Quick
            test_blocking_eio_cancellation_preserves_cancelled_identity;
          Alcotest.test_case "cause_of_exn distinguishes Exit from Cancelled" `Quick
            test_cause_of_exn_distinguishes_exit_from_cancelled;
        ] );
      ( "Supervisor",
        [
          Alcotest.test_case "observes child failure" `Quick
            test_supervisor_observes_child_failure;
          Alcotest.test_case "await rethrows child failure" `Quick
            test_supervisor_await_rethrows_child_failure;
          Alcotest.test_case "cancel runs finalizer" `Quick
            test_supervisor_cancel_runs_finalizer;
          Alcotest.test_case "cancel before await does not deadlock" `Quick
            test_supervisor_cancel_before_await_does_not_deadlock;
          Alcotest.test_case "cancel waits for finalizer" `Quick
            test_supervisor_cancel_waits_for_finalizer;
          Alcotest.test_case "with_background cancels child" `Quick
            test_effect_with_background_cancels_child;
          Alcotest.test_case "scope cancels unawaited children" `Quick
            test_supervisor_scope_cancels_unawaited_children_on_return;
          Alcotest.test_case "threshold failure" `Quick
            test_supervisor_threshold_failure;
          Alcotest.test_case "records multiple failures" `Quick
            test_supervisor_records_multiple_failures;
          Alcotest.test_case "nested scopes compose" `Quick
            test_supervisor_nested_scopes_compose;
        ] );
      ( "Clock",
        [
          Alcotest.test_case "sleep without wall time" `Quick
            test_clock_sleep_without_wall_time;
          Alcotest.test_case "sleep delays until adjusted" `Quick
            test_clock_sleep_delays_until_adjusted;
          Alcotest.test_case "multiple sleeps" `Quick
            test_clock_sleep_handles_multiple_sleeps;
          Alcotest.test_case "set_time wakes due sleepers" `Quick
            test_clock_set_time_wakes_due_sleepers;
        ] );
      ( "Duration",
        [
          Alcotest.test_case "constructors" `Quick test_duration_constructors;
          Alcotest.test_case "ordering" `Quick test_duration_ordering;
          Alcotest.test_case "algebra" `Quick test_duration_algebra;
          Alcotest.test_case "overflow" `Quick test_duration_overflow;
          Alcotest.test_case "min max clamp" `Quick test_duration_min_max_clamp;
          Alcotest.test_case "zero detection and conversion" `Quick
            test_duration_zero_detection_and_conversion;
        ] );
      ( "Schedule",
        [
          Alcotest.test_case "recurs" `Quick test_recurs;
          Alcotest.test_case "recurs driver yields exactly n delays" `Quick
            test_recurs_driver_yields_exactly_n_delays;
          Alcotest.test_case "exponential" `Quick test_exponential;
          Alcotest.test_case "spaced fixed linear" `Quick
            test_spaced_fixed_linear;
          Alcotest.test_case "composition" `Quick test_schedule_composition;
          Alcotest.test_case "composition termination with driver" `Quick
            test_schedule_composition_termination_with_driver;
          Alcotest.test_case "and_then offsets second phase" `Quick
            test_schedule_and_then_offsets_second_phase;
          Alcotest.test_case "jittered uses random capability" `Quick
            test_schedule_jittered_uses_random_capability;
          Alcotest.test_case "jittered stays inside multiplier bounds" `Quick
            test_schedule_jittered_stays_inside_multiplier_bounds;
          Alcotest.test_case "random float distribution and determinism" `Quick
            test_random_float_distribution_and_determinism;
        ] );
      ( "Scope",
        [
          Alcotest.test_case "finalizers run lifo sequentially" `Quick
            test_scope_finalizers_run_lifo_sequentially;
        ] );
      ( "Resource",
        [
          Alcotest.test_case "manual refresh" `Quick test_resource_manual_refresh;
          Alcotest.test_case "failed refresh keeps cached value" `Quick
            test_resource_failed_refresh_keeps_cached_value;
          Alcotest.test_case "auto refreshes on schedule" `Quick
            test_resource_auto_refreshes_on_schedule;
          Alcotest.test_case "auto failed refresh keeps cached value" `Quick
            test_resource_auto_failed_refresh_keeps_cached_value;
          Alcotest.test_case "auto records loader defect and continues" `Quick
            test_resource_auto_records_loader_defect_and_continues;
          Alcotest.test_case "auto records on_error defect and continues" `Quick
            test_resource_auto_records_on_error_defect_and_continues;
        ] );
      ( "Portable_queue",
        [
          Alcotest.test_case "backpressure and close" `Quick
            test_portable_queue_backpressure_and_close;
          Alcotest.test_case "no false empty under contention" `Quick
            test_portable_queue_no_false_empty_under_contention;
        ] );
      ( "Queue",
        [
          Alcotest.test_case "send recv close" `Quick test_queue_send_recv_close;
          Alcotest.test_case "close fence" `Quick test_queue_close_fence;
          Alcotest.test_case "close with error drains" `Quick
            test_queue_close_with_error_drains;
          Alcotest.test_case "cancel blocked recv" `Quick
            test_queue_cancel_blocked_recv_cleans_waiter;
        ] );
      ( "Channel",
        [
          Alcotest.test_case "try send recv" `Quick test_channel_try_send_try_recv;
          Alcotest.test_case "fifo send recv" `Quick
            test_channel_fifo_send_recv;
          Alcotest.test_case "blocking send backpressure" `Quick
            test_channel_blocking_send_backpressure;
          Alcotest.test_case "blocked sender not passed" `Quick
            test_channel_blocked_sender_is_not_passed_by_later_sender;
          Alcotest.test_case "blocking recv" `Quick test_channel_blocking_recv;
          Alcotest.test_case "close wakes blocked users" `Quick
            test_channel_close_wakes_blocked_senders_and_receivers;
          Alcotest.test_case "close with error drains" `Quick
            test_channel_close_with_error_drains_buffer;
          Alcotest.test_case "close drains buffer then reports closed" `Quick
            test_channel_close_drains_buffer_then_reports_closed;
          Alcotest.test_case "cancel blocked send" `Quick
            test_channel_cancel_blocked_send_cleans_waiter;
          Alcotest.test_case "cancel blocked recv" `Quick
            test_channel_cancel_blocked_recv_cleans_waiter;
          Alcotest.test_case "cancel delivered recv requeues" `Quick
            test_channel_cancel_receiver_after_delivery_requeues_message;
          Alcotest.test_case "cancel receiver overflow does not corrupt" `Quick
            test_channel_cancel_receiver_overflow_does_not_corrupt;
          Alcotest.test_case "parent switch teardown" `Quick
            test_channel_parent_switch_teardown_does_not_hang;
        ] );
      ( "Pubsub",
        [
          Alcotest.test_case "unbounded broadcasts" `Quick
            test_pubsub_unbounded_broadcasts_to_current_subscribers;
          Alcotest.test_case "one publisher one subscriber order" `Quick
            test_pubsub_one_publisher_one_subscriber_preserves_order;
          Alcotest.test_case "publish without subscribers does not retain"
            `Quick test_pubsub_publish_without_subscribers_does_not_retain_messages;
          Alcotest.test_case "late subscriber only receives later messages"
            `Quick test_pubsub_late_subscriber_only_receives_later_messages;
          Alcotest.test_case "many publishers many subscribers" `Quick
            test_pubsub_many_publishers_many_subscribers_preserve_message_sets;
          Alcotest.test_case "drop_new global capacity" `Quick
            test_pubsub_drop_new_uses_global_capacity;
          Alcotest.test_case "backpressure canceled publish atomic" `Quick
            test_pubsub_backpressure_canceled_publish_is_atomic;
          Alcotest.test_case "backpressure waits for lagging subscriber"
            `Quick
            test_pubsub_backpressure_waits_for_lagging_subscriber;
          Alcotest.test_case "backpressure close wakes publisher" `Quick
            test_pubsub_close_wakes_blocked_backpressure_publisher;
          Alcotest.test_case "close wakes blocked subscriber" `Quick
            test_pubsub_close_wakes_blocked_subscriber;
          Alcotest.test_case "close with error drains" `Quick
            test_pubsub_close_with_error_drains_buffer;
          Alcotest.test_case "subscription cancellation cleanup" `Quick
            test_pubsub_subscription_cleanup_on_body_cancellation;
          Alcotest.test_case "cancel blocked recv" `Quick
            test_pubsub_cancel_blocked_recv_cleans_waiter;
          Alcotest.test_case "invalid capacity rejected" `Quick
            test_pubsub_invalid_capacity_rejected;
        ] );
      ( "Pool",
        [
          Alcotest.test_case "reuses idle LIFO" `Quick
            test_pool_reuses_idle_lifo;
          Alcotest.test_case "body success releases resource" `Quick
            test_pool_with_resource_body_success_releases_resource;
          Alcotest.test_case "body typed failure releases resource" `Quick
            test_pool_with_resource_body_typed_failure_releases_resource;
          Alcotest.test_case "body defect releases resource" `Quick
            test_pool_with_resource_body_defect_releases_resource;
          Alcotest.test_case "release defect releases capacity" `Quick
            test_pool_release_defect_releases_capacity;
          Alcotest.test_case "max size under concurrent checkout" `Quick
            test_pool_max_size_respected_under_concurrent_checkout;
          Alcotest.test_case "timeout cleans waiter" `Quick
            test_pool_timeout_cleans_waiter_and_preserves_timeout_cause;
          Alcotest.test_case "health rejection reopens" `Quick
            test_pool_health_rejection_reopens;
          Alcotest.test_case "acquire failure does not consume capacity" `Quick
            test_pool_acquire_failure_does_not_count_as_active_resource;
          Alcotest.test_case "idle health failure rejects entry" `Quick
            test_pool_idle_health_failure_rejects_entry;
          Alcotest.test_case "idle health defect closes entry" `Quick
            test_pool_idle_health_defect_closes_entry;
          Alcotest.test_case "cancel during health check" `Quick
            test_pool_cancel_during_health_check_closes_reserved;
          Alcotest.test_case "idle eviction" `Quick test_pool_idle_eviction;
          Alcotest.test_case "expired idle preserves capacity waiters" `Quick
            test_pool_expired_idle_cleanup_preserves_capacity_waiters;
          Alcotest.test_case "shutdown wakes and drains" `Quick
            test_pool_shutdown_wakes_waiters_and_drains;
          Alcotest.test_case "shutdown waits for active close" `Quick
            test_pool_shutdown_waits_for_active_close;
          Alcotest.test_case "shutdown deadline" `Quick
            test_pool_shutdown_deadline_timeout;
          Alcotest.test_case "release detects active underflow" `Quick
            test_pool_release_detects_active_underflow;
          Alcotest.test_case "observability signals" `Quick
            test_pool_observability_signals;
        ] );
      ( "Semaphore",
        [
          Alcotest.test_case "make and available" `Quick
            test_semaphore_make_available;
          Alcotest.test_case "make rejects zero permits" `Quick
            test_semaphore_make_rejects_zero_permits;
          Alcotest.test_case "acquire reduces available" `Quick
            test_semaphore_acquire_reduces_available;
          Alcotest.test_case "release increases available" `Quick
            test_semaphore_release_increases_available;
          Alcotest.test_case "release rejects negative count" `Quick
            test_semaphore_release_rejects_negative_count;
          Alcotest.test_case "release rejects zero count" `Quick
            test_semaphore_release_rejects_zero_count;
          Alcotest.test_case "release over capacity clamps" `Quick
            test_semaphore_release_over_capacity_clamps;
          Alcotest.test_case "rejects over-capacity acquire" `Quick
            test_semaphore_rejects_over_capacity_acquire;
          Alcotest.test_case "rejects over-capacity try_acquire" `Quick
            test_semaphore_rejects_over_capacity_try_acquire;
          Alcotest.test_case "acquire at capacity succeeds" `Quick
            test_semaphore_acquire_at_capacity_succeeds;
          Alcotest.test_case "try_acquire is atomic" `Quick
            test_semaphore_try_acquire_is_atomic;
          Alcotest.test_case "with_permits releases on success" `Quick
            test_semaphore_with_permits_releases_on_success;
          Alcotest.test_case "with_permits releases on failure" `Quick
            test_semaphore_with_permits_releases_on_failure;
          Alcotest.test_case "with_permits releases on defect" `Quick
            test_semaphore_with_permits_releases_on_defect;
          Alcotest.test_case "with_permits releases on timeout" `Quick
            test_semaphore_with_permits_releases_on_timeout;
          Alcotest.test_case "cancellation stress" `Quick
            test_semaphore_cancellation_stress;
          Alcotest.test_case "cancel after wakeup returns permit" `Quick
            test_semaphore_cancel_after_wakeup_returns_permit;
          Alcotest.test_case "fifo wakes waiters in order" `Quick
            test_semaphore_fifo_wakes_waiters_in_order;
          Alcotest.test_case "multi-permit contention" `Quick
            test_semaphore_multi_permit_contention;
        ] );
      ( "Properties",
        [
          Alcotest.test_case "monad laws" `Quick test_properties_monad_laws;
          Alcotest.test_case "catch laws" `Quick test_properties_catch_laws;
          Alcotest.test_case "race success invariant" `Quick
            test_properties_race_success_invariant;
          Alcotest.test_case "retry and repeat laws" `Quick
            test_properties_retry_and_repeat_laws;
          Alcotest.test_case "scope finalizers exactly once" `Quick
            test_properties_scope_finalizers_once;
        ] );
      ( "Observability",
        [
          Alcotest.test_case "manual tracer spans" `Quick
            test_tracer_manual_spans;
          Alcotest.test_case "named span status ok" `Quick
            test_observability_named_ok;
          Alcotest.test_case "span kind" `Quick test_observability_span_kind;
          Alcotest.test_case "fn records location" `Quick test_observability_fn_loc;
          Alcotest.test_case "annotate_all and fn attrs" `Quick
            test_observability_annotate_all_and_fn_attrs;
          Alcotest.test_case "event records current span" `Quick
            test_observability_event_records_current_span;
          Alcotest.test_case "with_result_attrs" `Quick
            test_observability_with_result_attrs;
          Alcotest.test_case "annotation order" `Quick
            test_observability_annotation_order;
          Alcotest.test_case "nested spans" `Quick test_observability_nested_spans;
          Alcotest.test_case "statuses" `Quick test_observability_statuses;
          Alcotest.test_case "concurrent status" `Quick
            test_observability_concurrent_status;
          Alcotest.test_case "cancelled child status" `Quick
            test_observability_cancelled_parallel_child_status;
          Alcotest.test_case "uninterruptible child status" `Quick
            test_observability_uninterruptible_parallel_child_status;
          Alcotest.test_case "par children inherit parent" `Quick
            test_observability_par_children_inherit_parent;
          Alcotest.test_case "par pending attrs links are fiber-local" `Quick
            test_observability_par_pending_attrs_links_are_fiber_local;
          Alcotest.test_case "sampler always off" `Quick
            test_observability_sampler_always_off;
          Alcotest.test_case "sampler ratio" `Quick
            test_observability_sampler_ratio;
          Alcotest.test_case "sampler ratio same name uses trace id" `Quick
            test_observability_sampler_ratio_same_name_uses_trace_id;
          Alcotest.test_case "sampler parent based" `Quick
            test_observability_sampler_parent_based;
          Alcotest.test_case "sampler suppresses par children" `Quick
            test_observability_sampler_unsampled_parent_suppresses_par_children;
          Alcotest.test_case "noop runtime keeps die diagnostics" `Quick
            test_observability_noop_runtime_keeps_die_diagnostics;
          Alcotest.test_case "custom noop tracer is explicitly enabled" `Quick
            test_observability_custom_noop_tracer_is_explicitly_enabled;
          Alcotest.test_case "suppress observability" `Quick
            test_observability_suppress_observability;
          Alcotest.test_case "trace context extract inject" `Quick
            test_trace_context_extract_inject;
          Alcotest.test_case "trace context rejects malformed traceparent" `Quick
            test_trace_context_rejects_malformed_traceparent;
          Alcotest.test_case "trace context par inherits baggage" `Quick
            test_trace_context_current_and_par_inherit_baggage;
          Alcotest.test_case "in-memory tracer current span has valid ids"
            `Quick test_in_memory_tracer_current_span_has_valid_ids;
          Alcotest.test_case "in-memory tracer child inherits trace id" `Quick
            test_in_memory_tracer_child_inherits_trace_id;
          Alcotest.test_case "in-memory tracer external trace id wins" `Quick
            test_in_memory_tracer_external_context_trace_id_wins;
          Alcotest.test_case "trace context unsampled parent suppresses child"
            `Quick
            test_trace_context_unsampled_parent_suppresses_child;
          Alcotest.test_case "auto instrument default off" `Quick
            test_observability_auto_instrument_default_off;
          Alcotest.test_case "auto instrument sync leaves" `Quick
            test_observability_auto_instrument_eval_leaves;
          Alcotest.test_case "auto instrument leaves nest" `Quick
            test_observability_auto_instrument_leaves_nest_under_named;
          Alcotest.test_case "auto instrument failure status" `Quick
            test_observability_auto_instrument_failure_status;
          Alcotest.test_case "all for_each_par supervisor inherit parent" `Quick
            test_observability_all_for_each_supervisor_inherit_parent;
        ] );
      ( "Eta_redacted",
        [
          Alcotest.test_case "pp unlabelled" `Quick test_redacted_pp_unlabelled;
          Alcotest.test_case "pp labelled" `Quick test_redacted_pp_labelled;
          Alcotest.test_case "equal" `Quick test_redacted_equal;
          Alcotest.test_case "hash" `Quick test_redacted_hash;
          Alcotest.test_case "wipe_unsafe" `Quick test_redacted_wipe_unsafe;
          Alcotest.test_case "label" `Quick test_redacted_label;
        ] );
      ( "Stress",
        [
          Alcotest.test_case "pool no resource leak" `Quick
            test_pool_stress_no_resource_leak;
          Alcotest.test_case "semaphore permit accounting" `Quick
            test_semaphore_stress_permit_accounting;
          Alcotest.test_case "channel no lost messages" `Quick
            test_channel_stress_no_lost_messages;
          Alcotest.test_case "retry resource accumulation systematic" `Quick
            test_retry_resource_accumulation_systematic;
          Alcotest.test_case "nested scope catch retry releases all" `Quick
            test_nested_scope_catch_retry_releases_all;
          Alcotest.test_case "race+retry resources released on scope exit" `Quick
            test_race_retry_accumulated_resources_released_on_scope_exit;
          Alcotest.test_case "all_settled scoped resources released" `Quick
            test_all_settled_scoped_resources_released_per_branch;
          Alcotest.test_case "race many branches resource cleanup" `Quick
            test_race_many_branches_resource_cleanup;
          Alcotest.test_case "randomized effect compositions release" `Quick
            test_randomized_effect_compositions_release_resources;
          Alcotest.test_case "randomized race compositions release" `Quick
            test_randomized_race_compositions_release_resources;
          Alcotest.test_case "randomized all compositions release" `Quick
            test_randomized_all_compositions_release_resources;
          Alcotest.test_case "for_each_par cancelled workers release" `Quick
            test_for_each_par_cancelled_workers_release_resources;
          Alcotest.test_case "par scoped resource released on failure" `Quick
            test_par_scoped_resource_released_on_failure;
          Alcotest.test_case "all without scoped releases at scope exit" `Quick
            test_all_without_scoped_releases_at_scope_exit;
        ] );
    ]
