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
          Alcotest.test_case "eta pool adapter uses eta pool" `Quick
            test_sql_eta_pool_adapter_uses_eta_pool;
          Alcotest.test_case "eta pool fold scans in batches" `Quick
            test_sql_eta_pool_fold_scans_in_batches;
          Alcotest.test_case "eta pool executes typed compiled queries" `Quick
            test_sql_eta_pool_typed_compiled_queries;
          Alcotest.test_case "eta pool timeout interrupts and reuses connection"
            `Quick test_sql_eta_pool_timeout_interrupts_and_reuses_connection;
          Alcotest.test_case
            "eta pool parent cancel interrupts and reuses connection" `Quick
            test_sql_eta_pool_parent_cancel_interrupts_and_reuses_connection;
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
        ] );
      ( "Sqlite",
        [
          Alcotest.test_case "memory prepare bind scan" `Quick
            test_sqlite_memory_prepare_bind_scan;
          Alcotest.test_case "structured prepare error" `Quick
            test_sqlite_structured_prepare_error;
          Alcotest.test_case "range and constraint errors" `Quick
            test_sqlite_range_and_constraint_errors;
          Alcotest.test_case "close with live statement" `Quick
            test_sqlite_close_with_live_statement;
          Alcotest.test_case "path and read only mode" `Quick
            test_sqlite_path_and_read_only_mode;
          Alcotest.test_case "config exec script and pragmas" `Quick
            test_sqlite_config_exec_script_and_pragmas;
          Alcotest.test_case "transactions and savepoints" `Quick
            test_sqlite_transactions_and_savepoints;
          Alcotest.test_case "float blob metadata and counters" `Quick
            test_sqlite_float_blob_metadata_and_counters;
          Alcotest.test_case "backup and restore" `Quick
            test_sqlite_backup_and_restore;
          Alcotest.test_case "load extension toggle" `Quick
            test_sqlite_load_extension_toggle;
          Alcotest.test_case "config error and testing helpers" `Quick
            test_sqlite_config_error_and_testing_helpers;
        ] );
    ]
