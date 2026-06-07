open Bugs

let () =
  Alcotest.run "Eta bug hunt"
    [
      ( "runtime",
        [
          Alcotest.test_case "Duration.scale by 1.0 is identity at max" `Quick
            test_duration_scale_identity_at_max;
          Alcotest.test_case "jittered exponential backoff never raises" `Quick
            test_schedule_jittered_exponential_does_not_raise;
        ] );
      ( "eta_sql",
        [
          Alcotest.test_case "float column DEFAULT round-trips" `Quick
            test_schema_float_default_round_trips;
          Alcotest.test_case "NULL decoded as non-nullable int" `Quick
            test_sqlite_null_decoded_as_nonnull_int;
        ] );
      ( "eta_duckdb",
        [
          Alcotest.test_case "LIST column alongside TIMESTAMP decodes" `Quick
            test_duckdb_list_alongside_timestamp_column;
          Alcotest.test_case "execute reports changed-row count" `Quick
            test_duckdb_execute_reports_changed_rows;
          Alcotest.test_case "UUID decodes to text" `Quick
            test_duckdb_uuid_decodes_to_text;
        ] );
      ( "eta_turso",
        [
          Alcotest.test_case "exec_script runs every statement" `Quick
            test_turso_exec_script_runs_every_statement;
        ] );
      ( "eta_ladybug",
        [
          Alcotest.test_case "LIST value decodes as a list" `Quick
            test_ladybug_list_decodes_as_list;
          Alcotest.test_case "Rel value decodes as Rel" `Quick
            test_ladybug_rel_decodes_as_rel;
          Alcotest.test_case "Path value decodes as Path" `Quick
            test_ladybug_path_decodes_as_path;
          Alcotest.test_case "timestamp not empty string" `Quick
            test_ladybug_timestamp_not_empty_string;
          Alcotest.test_case "Param.map round-trips as Map" `Quick
            test_ladybug_param_map_round_trips;
        ] );
    ]
