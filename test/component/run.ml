open Test_eta_component

let () =
  Alcotest.run "eta_component"
    [
      ( "Component",
        [
          Alcotest.test_case "bare context runs and stops" `Quick
            test_bare_context;
          Alcotest.test_case "schema key uniqueness" `Quick
            test_component_schema_key_uniqueness;
          Alcotest.test_case "reconcile activates one component" `Quick
            test_reconcile_activates_component;
          Alcotest.test_case "lifecycle inertia and retry" `Quick
            test_component_lifecycle_inertia_and_retry;
          Alcotest.test_case "recovery lifo and cleanup at most once" `Quick
            test_component_recovery_lifo_and_cleanup_at_most_once;
          Alcotest.test_case "callback boundary matrix" `Quick
            test_component_callback_boundary_matrix;
          Alcotest.test_case "failure locality and quarantine fence" `Quick
            test_component_failure_locality_and_quarantine_fence;
          Alcotest.test_case "shutdown fence idempotence" `Quick
            test_component_shutdown_fence_idempotence;
          Alcotest.test_case "desired admission atomic" `Quick
            test_component_desired_admission_atomic;
          Alcotest.test_case "telemetry noninterference" `Quick
            test_component_telemetry_noninterference;
          Alcotest.test_case "provider resolution" `Quick
            test_component_provider_resolution;
          Alcotest.test_case "provider withdrawal order" `Quick
            test_component_provider_withdrawal_order;
          Alcotest.test_case "equal value episode reactivation" `Quick
            test_component_equal_value_episode_reactivation;
          Alcotest.test_case "episode identity bijection" `Quick
            test_component_episode_identity_bijection;
          Alcotest.test_case "settlement report repeatability" `Quick
            test_component_settlement_report_repeatability;
          Alcotest.test_case "diagnostics revision atomicity" `Quick
            test_component_diagnostics_revision_atomicity;
          Alcotest.test_case "failure rendering stability" `Quick
            test_component_failure_rendering_stability;
          Alcotest.test_case "context lexical lifetime" `Quick
            test_component_context_lexical_lifetime;
          Alcotest.test_case "change wait race freedom" `Quick
            test_component_change_wait_race_freedom;
          Alcotest.test_case "replacement target revision fence" `Quick
            test_component_replacement_target_revision_fence;
          Alcotest.test_case "hmr rollback matrix" `Quick
            test_component_hmr_rollback_matrix;
          Alcotest.test_case "cycle rejection atomic" `Quick
            test_component_cycle_rejection_atomic;
          Alcotest.test_case "duplicate provider rejection" `Quick
            test_component_duplicate_provider_rejection;
          Alcotest.test_case "cause and quarantine matrix" `Quick
            test_component_cause_and_quarantine_matrix;
          Alcotest.test_case "interception metadata fold order" `Quick
            test_component_interception_metadata_fold_order;
          Alcotest.test_case "reconciliation identity rules" `Quick
            test_component_reconciliation_identity_rules;
          Alcotest.test_case "realm isolation" `Quick
            test_component_realm_isolation;
          Alcotest.test_case "direct lease cardinality" `Quick
            test_component_direct_lease_cardinality;
          Alcotest.test_case "replacement batch constructor matrix" `Quick
            test_component_replacement_batch_constructor_matrix;
          Alcotest.test_case "await change error matrix" `Quick
            test_component_await_change_error_matrix;
          Alcotest.test_case "release renderer failure" `Quick
            test_component_release_renderer_failure;
          Alcotest.test_case "post shutdown rejection" `Quick
            test_component_post_shutdown_rejection;
          Alcotest.test_case "group kind authority retention" `Quick
            test_component_group_kind_authority_retention;
          Alcotest.test_case "retire mid-activation interrupts" `Quick
            test_component_retire_mid_activation_interrupts;
          Alcotest.test_case "activation failure releases owned" `Quick
            test_component_activation_failure_releases_owned;
          Alcotest.test_case "provider withdrawal during activation" `Quick
            test_component_provider_withdrawal_during_activation;
          Alcotest.test_case "combined provider consumer update" `Quick
            test_component_combined_provider_consumer_update;
          Alcotest.test_case "consumer waits for gated provider" `Quick
            test_component_consumer_waits_for_gated_provider;
          Alcotest.test_case "topological activation chain" `Quick
            test_component_topological_activation_chain;
          Alcotest.test_case "group disable cascade" `Quick
            test_component_group_disable_cascade;
          Alcotest.test_case "group transfer matrix" `Quick
            test_component_group_transfer_matrix;
          Alcotest.test_case "disabled entry never activates" `Quick
            test_component_disabled_entry_never_activates;
          Alcotest.test_case "shared realm across groups" `Quick
            test_component_shared_realm_across_groups;
          Alcotest.test_case "isolate reassignment matrix" `Quick
            test_component_isolate_reassignment_matrix;
          Alcotest.test_case "named realm routing" `Quick
            test_component_named_realm_routing;
          Alcotest.test_case "group isolate switch reroutes" `Quick
            test_component_group_isolate_switch_reroutes;
          Alcotest.test_case "replace provider restarts consumer" `Quick
            test_component_replace_provider_restarts_consumer;
          Alcotest.test_case "replace leaves sibling untouched" `Quick
            test_component_replace_leaves_sibling_untouched;
          Alcotest.test_case "recovery replace after rollback" `Quick
            test_component_recovery_replace_after_rollback;
        ] );
    ]
