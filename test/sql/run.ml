open Test_sql
open Test_sqlite

let () =
  Alcotest.run "Eta SQL"
    [
      ( "Eta_sql",
        [
          Alcotest.test_case "select insert update delete" `Quick
            test_sql_select_insert_update_delete;
          Alcotest.test_case "render stable SQL" `Quick test_sql_render_stable_sql;
          Alcotest.test_case "aggregates distinct group having" `Quick
            test_sql_select_aggregates_distinct_group;
          Alcotest.test_case "subquery cte and window select" `Quick
            test_sql_select_subquery_cte_window;
          Alcotest.test_case "empty in values is false predicate" `Quick
            test_sql_in_values_empty_list_is_false_predicate;
          Alcotest.test_case "invalid query errors" `Quick
            test_sql_invalid_query_errors;
          Alcotest.test_case "find opt rejects many rows" `Quick
            test_sql_find_opt_rejects_many_rows;
          Alcotest.test_case "value and row helpers" `Quick
            test_sql_value_and_row_helpers;
          Alcotest.test_case "schema and join helpers" `Quick
            test_sql_schema_and_join_helpers;
          Alcotest.test_case "connection pool and transaction helpers" `Quick
            test_sql_connection_pool_and_transaction_helpers;
          Alcotest.test_case "pool waits timeouts and stale releases" `Quick
            test_sql_pool_waits_times_out_and_ignores_stale_release;
          Alcotest.test_case "connection rejects closed and invalid tx state"
            `Quick test_sql_connection_rejects_closed_and_invalid_transaction_state;
          Alcotest.test_case "pool adapter uses pool" `Quick
            test_sql_pool_adapter_uses_pool;
          Alcotest.test_case "pool fold scans in batches" `Quick
            test_sql_pool_fold_scans_in_batches;
          Alcotest.test_case "pool executes typed compiled queries" `Quick
            test_sql_pool_typed_compiled_queries;
          Alcotest.test_case "pool timeout interrupts and reuses connection"
            `Quick test_sql_pool_timeout_interrupts_and_reuses_connection;
          Alcotest.test_case "database pool shutdown keeps parent on timeout"
            `Quick test_database_pool_shutdown_keeps_parent_open_on_timeout;
          Alcotest.test_case "turso pool uses interruptible leased blocking"
            `Quick test_turso_pool_uses_shared_interruptible_leased_blocking_source;
          Alcotest.test_case
            "pool parent cancel interrupts and reuses connection" `Quick
            test_sql_pool_parent_cancel_interrupts_and_reuses_connection;
          Alcotest.test_case "pool rejects detach-started blocking pool" `Quick
            test_sql_pool_rejects_detach_started_blocking_pool;
          Alcotest.test_case "new expr operator workload" `Quick
            test_sql_new_expr_operator_workload;
          Alcotest.test_case "between in case aggregates having" `Quick
            test_sql_between_in_case_aggregates_having;
          Alcotest.test_case "migrations run run_to and undo" `Quick
            test_sql_migrations_run_run_to_and_undo;
          Alcotest.test_case "migrations reject dirty checksum and missing" `Quick
            test_sql_migrations_reject_dirty_checksum_and_missing;
          Alcotest.test_case "migration source resolution metadata" `Quick
            test_sql_migration_source_resolution_metadata;
          Alcotest.test_case "pool leaked transaction poisons next borrower" `Quick
            test_sql_pool_leaked_transaction_poisons_next_borrower;
          Alcotest.test_case "health check does not detect active transaction" `Quick
            test_sql_pool_health_check_does_not_detect_active_transaction;
          Alcotest.test_case "fold timeout does not bound total elapsed" `Slow
            test_sql_fold_timeout_does_not_bound_total_elapsed;
          Alcotest.test_case "compiled type bypass" `Quick
            test_sql_compiled_type_bypass;
          Alcotest.test_case "expr type unsoundness" `Quick
            test_sql_expr_type_unsoundness;
          Alcotest.test_case "schema DSL raw interpolation" `Quick
            test_sql_schema_dsl_raw_interpolation;
        ] );
      ( "Sqlite",
        [
          Alcotest.test_case "memory prepare bind scan" `Quick
            test_sqlite_memory_prepare_bind_scan;
          Alcotest.test_case "structured prepare error" `Quick
            test_sqlite_structured_prepare_error;
          Alcotest.test_case "range and constraint errors" `Quick
            test_sqlite_range_and_constraint_errors;
          Alcotest.test_case "column int rejects out of OCaml range" `Quick
            test_sqlite_column_int_rejects_out_of_ocaml_range;
          Alcotest.test_case "close with live statement" `Quick
            test_sqlite_close_with_live_statement;
          Alcotest.test_case "path and read only mode" `Quick
            test_sqlite_path_and_read_only_mode;
          Alcotest.test_case "config exec script and pragmas" `Quick
            test_sqlite_config_exec_script_and_pragmas;
          Alcotest.test_case "transactions and savepoints" `Quick
            test_sqlite_transactions_and_savepoints;
          Alcotest.test_case "transaction commit failure rolls back" `Quick
            test_sqlite_transaction_commit_failure_rolls_back;
          Alcotest.test_case "float blob metadata and counters" `Quick
            test_sqlite_float_blob_metadata_and_counters;
          Alcotest.test_case "backup and restore" `Quick
            test_sqlite_backup_and_restore;
          Alcotest.test_case "backup waits without busy spinning" `Quick
            test_sqlite_backup_waits_without_busy_spinning;
          Alcotest.test_case "load extension toggle" `Quick
            test_sqlite_load_extension_toggle;
          Alcotest.test_case "config error and testing helpers" `Quick
            test_sqlite_config_error_and_testing_helpers;
          Alcotest.test_case "unexpected step success is typed error" `Quick
            test_sqlite_unexpected_step_success_is_typed_error;
        ] );
    ]
