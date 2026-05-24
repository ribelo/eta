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
open Test_eta_channel
open Test_eta_pool
open Test_eta_semaphore
open Test_eta_properties
open Test_eta_observability
open Test_eta_redacted

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
          Alcotest.test_case "all fail-fast" `Quick test_all_fail_fast;
          Alcotest.test_case "all_settled collects outcomes" `Quick
            test_all_settled_collects_successes_and_failures;
          Alcotest.test_case "all_settled runs all children" `Quick
            test_all_settled_runs_all_children;
          Alcotest.test_case "all_settled timeout scoped resource typed" `Quick
            test_all_settled_timeout_scoped_resource_is_typed;
          Alcotest.test_case "all_settled empty" `Quick test_all_settled_empty;
          Alcotest.test_case "for_each_par success" `Quick
            test_for_each_par_success;
          Alcotest.test_case "for_each_par one fails" `Quick
            test_for_each_par_one_fails;
          Alcotest.test_case "for_each_par_bounded caps concurrency" `Quick
            test_for_each_par_bounded_caps_concurrency;
          Alcotest.test_case "for_each_par_bounded max one is sequential" `Quick
            test_for_each_par_bounded_max_one_is_sequential;
          Alcotest.test_case "for_each_par_bounded fail-fast" `Quick
            test_for_each_par_bounded_fail_fast;
          Alcotest.test_case "collect_names" `Quick test_collect_names;
          Alcotest.test_case "map bind tap runtime" `Quick
            test_effect_map_bind_tap_runtime;
          Alcotest.test_case "catch success and failure" `Quick
            test_effect_catch_success_and_failure;
          Alcotest.test_case "catch handler failure uses outer key" `Quick
            test_effect_catch_handler_failure_uses_outer_key;
          Alcotest.test_case "tap_error observes and rethrows" `Quick
            test_effect_tap_error_observes_and_rethrows;
          Alcotest.test_case "tap_error observer failure preserves typed failure"
            `Quick
            test_effect_tap_error_observer_failure_preserves_typed_failure;
          Alcotest.test_case "empty cause aggregations reject" `Quick
            test_cause_empty_aggregations_reject;
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
          Alcotest.test_case "concurrent child die captures diagnostics" `Quick
            test_runtime_concurrent_child_die_captures_diagnostics;
          Alcotest.test_case "finalizer die captures diagnostics" `Quick
            test_runtime_finalizer_die_captures_diagnostics;
          Alcotest.test_case "catch does not catch interrupt" `Quick
            test_effect_catch_does_not_catch_interrupt;
          Alcotest.test_case "acquire release" `Quick test_acquire_release;
          Alcotest.test_case "acquire release root finalizer" `Quick
            test_acquire_release_root_scope_runs_finalizer;
          Alcotest.test_case "acquire release root failure finalizer" `Quick
            test_acquire_release_root_scope_runs_finalizer_on_failure;
          Alcotest.test_case "daemon drains acquire release finalizer" `Quick
            test_daemon_drains_acquire_release_finalizer;
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
          Alcotest.test_case "timeout_as nested maps outer timeout" `Quick
            test_effect_timeout_as_nested_cancel_maps_to_outer_timeout;
          Alcotest.test_case "race ignores early failure until success" `Quick
            test_effect_race_ignores_early_failure_until_success;
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
          Alcotest.test_case "par nested race failures baseline" `Quick
            test_par_nested_race_all_failures_baseline;
          Alcotest.test_case "repeat schedule" `Quick test_effect_repeat_schedule;
          Alcotest.test_case "repeat schedule uses virtual delays" `Quick
            test_effect_repeat_schedule_uses_virtual_delays;
          Alcotest.test_case "retry schedule until success" `Quick
            test_effect_retry_schedule_until_success;
          Alcotest.test_case "retry schedule uses virtual delays" `Quick
            test_effect_retry_schedule_uses_virtual_delays;
          Alcotest.test_case "retry jittered schedule uses runtime random" `Quick
            test_effect_retry_jittered_schedule_uses_runtime_random;
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
        ] );
      ( "Schedule",
        [
          Alcotest.test_case "recurs" `Quick test_recurs;
          Alcotest.test_case "exponential" `Quick test_exponential;
          Alcotest.test_case "spaced fixed linear" `Quick
            test_spaced_fixed_linear;
          Alcotest.test_case "composition" `Quick test_schedule_composition;
          Alcotest.test_case "and_then offsets second phase" `Quick
            test_schedule_and_then_offsets_second_phase;
          Alcotest.test_case "jittered uses random capability" `Quick
            test_schedule_jittered_uses_random_capability;
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
        ] );
      ( "Channel",
        [
          Alcotest.test_case "try send recv" `Quick test_channel_try_send_try_recv;
          Alcotest.test_case "blocking send backpressure" `Quick
            test_channel_blocking_send_backpressure;
          Alcotest.test_case "blocked sender not passed" `Quick
            test_channel_blocked_sender_is_not_passed_by_later_sender;
          Alcotest.test_case "blocking recv" `Quick test_channel_blocking_recv;
          Alcotest.test_case "close wakes blocked users" `Quick
            test_channel_close_wakes_blocked_senders_and_receivers;
          Alcotest.test_case "cancel blocked send" `Quick
            test_channel_cancel_blocked_send_cleans_waiter;
          Alcotest.test_case "cancel blocked recv" `Quick
            test_channel_cancel_blocked_recv_cleans_waiter;
          Alcotest.test_case "cancel delivered recv requeues" `Quick
            test_channel_cancel_receiver_after_delivery_requeues_message;
          Alcotest.test_case "parent switch teardown" `Quick
            test_channel_parent_switch_teardown_does_not_hang;
        ] );
      ( "Pool",
        [
          Alcotest.test_case "reuses idle LIFO" `Quick
            test_pool_reuses_idle_lifo;
          Alcotest.test_case "timeout cleans waiter" `Quick
            test_pool_timeout_cleans_waiter_and_preserves_timeout_cause;
          Alcotest.test_case "health rejection reopens" `Quick
            test_pool_health_rejection_reopens;
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
          Alcotest.test_case "with_permits releases on success" `Quick
            test_semaphore_with_permits_releases_on_success;
          Alcotest.test_case "with_permits releases on failure" `Quick
            test_semaphore_with_permits_releases_on_failure;
          Alcotest.test_case "with_permits releases on timeout" `Quick
            test_semaphore_with_permits_releases_on_timeout;
          Alcotest.test_case "cancellation stress" `Quick
            test_semaphore_cancellation_stress;
          Alcotest.test_case "cancel after wakeup returns permit" `Quick
            test_semaphore_cancel_after_wakeup_returns_permit;
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
      ( "Redacted",
        [
          Alcotest.test_case "pp unlabelled" `Quick test_redacted_pp_unlabelled;
          Alcotest.test_case "pp labelled" `Quick test_redacted_pp_labelled;
          Alcotest.test_case "equal" `Quick test_redacted_equal;
          Alcotest.test_case "hash" `Quick test_redacted_hash;
          Alcotest.test_case "wipe_unsafe" `Quick test_redacted_wipe_unsafe;
          Alcotest.test_case "label" `Quick test_redacted_label;
        ] );
    ]
