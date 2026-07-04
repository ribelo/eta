open Test_eta_effect_core
open Test_eta_effect_retry_repeat
open Test_eta_effect_resource_timeout
open Test_eta_effect_uninterruptible
open Test_eta_blocking
open Test_eta_supervisor
open Test_eta_channel
open Test_eta_queue
open Test_eta_sync_lock
open Test_eta_observability

let () =
  Alcotest.run "eta"
    [
      ( "Effect",
        [
          Alcotest.test_case "scoped creates switch in fiberless host run"
            `Quick
            test_effect_scoped_creates_switch_in_fiberless_host_run;
          Alcotest.test_case "fiberless frame is domain local" `Quick
            test_effect_fiberless_frame_is_domain_local;
          Alcotest.test_case "finally runs on eio cancellation" `Quick
            test_effect_finally_runs_on_eio_cancellation;
          Alcotest.test_case
            "finally cleanup failure during eio cancellation is diagnostic"
            `Quick
            test_effect_finally_cleanup_failure_during_eio_cancellation_is_diagnostic;
          Alcotest.test_case "runtime run propagates eio cancellation" `Quick
            test_runtime_run_propagates_eio_cancellation;
          Alcotest.test_case "eio runtime contract same-domain callbacks"
            `Quick
            test_eio_runtime_contract_callbacks_stay_on_owner_domain;
          Alcotest.test_case "timeout cancellation stays on owner domain"
            `Quick
            test_effect_timeout_cancellation_stays_on_owner_domain;
          Alcotest.test_case "catch preserves concurrent interrupt" `Quick
            test_effect_catch_preserves_concurrent_interrupt;
          Alcotest.test_case "drain does not busy wait" `Quick
            test_drain_does_not_busy_wait;
          Alcotest.test_case "retry preserves structured exception causes"
            `Quick
            test_effect_retry_preserves_structured_exception_causes;
          Alcotest.test_case "uninterruptible no-checkpoint loser" `Quick
            test_uninterruptible_race_loser_without_checkpoints_returns;
        ] );
      ( "Blocking",
        [
          Alcotest.test_case "custom runner" `Quick
            test_blocking_pool_custom_runner;
          Alcotest.test_case "runner cancellation releases started slot" `Quick
            test_blocking_runner_cancellation_releases_started_slot;
          Alcotest.test_case "direct control and heartbeat" `Quick
            test_blocking_direct_control_and_blocking_heartbeat;
          Alcotest.test_case "wait caps active and queue" `Quick
            test_blocking_wait_policy_caps_active_and_queue;
          Alcotest.test_case "wait policy no lost wakeup under churn" `Quick
            test_blocking_wait_policy_no_lost_wakeup_under_churn;
          Alcotest.test_case "pending cancellation" `Quick
            test_blocking_pending_cancellation_removes_queued_job;
          Alcotest.test_case "shutdown detach records" `Quick
            test_blocking_shutdown_detach_started_returns_promptly;
          Alcotest.test_case "detach started counts each job once" `Quick
            test_blocking_detach_started_counts_each_job_once;
          Alcotest.test_case "named pools isolate" `Quick
            test_blocking_named_pools_prevent_starvation;
          Alcotest.test_case "cpu antipattern" `Quick
            test_blocking_cpu_antipattern_has_no_speedup;
          Alcotest.test_case "observability labels timings" `Quick
            test_blocking_observability_labels_and_timings;
          Alcotest.test_case "eio cancellation preserves Cancelled identity" `Quick
            test_blocking_eio_cancellation_preserves_cancelled_identity;
          Alcotest.test_case "cause_of_exn distinguishes Exit from Cancelled" `Quick
            test_cause_of_exn_distinguishes_exit_from_cancelled;
        ] );
      ( "Supervisor",
        [
          Alcotest.test_case "scope cancels unawaited children" `Quick
            test_supervisor_scope_cancels_unawaited_children_on_return;
        ] );
      ( "Channel",
        [
          Alcotest.test_case "cancel delivered recv requeues" `Quick
            test_channel_cancel_receiver_after_delivery_requeues_message;
          Alcotest.test_case "cancel receiver overflow does not corrupt" `Quick
            test_channel_cancel_receiver_overflow_does_not_corrupt;
          Alcotest.test_case "parent switch teardown" `Quick
            test_channel_parent_switch_teardown_does_not_hang;
        ] );
      ( "Queue",
        [
          Alcotest.test_case "rejects cross-domain use" `Quick
            test_queue_rejects_cross_domain_use;
          Alcotest.test_case "backpressure sender wakeup stays on owner domain"
            `Quick test_queue_backpressure_sender_wakeup_stays_on_owner_domain;
          Alcotest.test_case "receiver wakeup stays on owner domain" `Quick
            test_queue_receiver_wakeup_stays_on_owner_domain;
          Alcotest.test_case "receiver wakeup reserves value" `Quick
            test_queue_receiver_wakeup_reserves_value_for_waiter;
          Alcotest.test_case "resolves sender outside lock" `Quick
            test_queue_resolves_sender_outside_lock;
          Alcotest.test_case "recv committed result survives wakeup failure"
            `Quick test_queue_recv_result_survives_sender_wakeup_failure;
          Alcotest.test_case
            "backpressure admission wins racing cancellation" `Quick
            test_queue_backpressure_admission_wins_racing_cancellation;
          Alcotest.test_case "take_batch wakes interrupted admission" `Quick
            test_queue_take_batch_interrupted_wakeup_still_admits_sender;
          Alcotest.test_case "take_all wakes interrupted admission" `Quick
            test_queue_take_all_interrupted_wakeup_still_admits_sender;
          Alcotest.test_case "try_recv wakes interrupted admission" `Quick
            test_queue_try_recv_interrupted_wakeup_still_admits_sender;
          Alcotest.test_case "recv wakes interrupted admission" `Quick
            test_queue_recv_interrupted_wakeup_still_admits_sender;
          Alcotest.test_case "close wakes interrupted sender" `Quick
            test_queue_close_interrupted_wakeup_still_wakes_sender;
          Alcotest.test_case "try_recv wakeup retry" `Quick
            test_queue_try_recv_admitted_sender_is_woken_even_if_resolver_raises;
          Alcotest.test_case "recv wakeup retry" `Quick
            test_queue_recv_admitted_sender_is_woken_even_if_resolver_raises;
          Alcotest.test_case "take_all wakeup retry" `Quick
            test_queue_take_all_admitted_sender_is_woken_even_if_resolver_raises;
          Alcotest.test_case "take_batch wakeup retry" `Quick
            test_queue_take_batch_admitted_sender_is_woken_even_if_resolver_raises;
          Alcotest.test_case "close wakeup retry" `Quick
            test_queue_close_senders_are_woken_even_if_resolver_raises;
          Alcotest.test_case "unbounded offer never reports full" `Quick
            test_queue_unbounded_offer_never_reports_full;
          Alcotest.test_case "backpressure offer waits instead of full" `Quick
            test_queue_backpressure_offer_waits_instead_of_returning_full;
          Alcotest.test_case "recv waits instead of empty" `Quick
            test_queue_recv_waits_instead_of_returning_empty;
          Alcotest.test_case "stats counters saturate" `Quick
            test_queue_stats_counters_saturate;
        ] );
      ( "Sync_lock",
        [
          Alcotest.test_case "reentrant use fails fast" `Quick
            test_sync_lock_reentrant_use_fails_fast;
          Alcotest.test_case "cross-domain contention waits" `Quick
            test_sync_lock_cross_domain_contention_waits;
          Alcotest.test_case "runtime operation under lock fails fast" `Quick
            test_sync_lock_rejects_runtime_operation;
          Alcotest.test_case
            "runtime contract operation under lock fails fast" `Quick
            test_sync_lock_rejects_runtime_contract_operation;
        ] );
      ( "Observability",
        [
          Alcotest.test_case "eio interrupt status" `Quick
            test_observability_eio_interrupt_status;
        ] );
    ]
