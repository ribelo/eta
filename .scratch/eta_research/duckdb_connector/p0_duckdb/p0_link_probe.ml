(** P0 DuckDB link probe — confirms libduckdb is reachable and functional. *)

let () =
  Printf.printf "=== P0 DuckDB Link Probe ===\n\n";
  Printf.printf "duckdb_version=%s\n" (P0_duckdb.duckdb_version ());
  Printf.printf "%s\n" (P0_duckdb.duckdb_smoke ());
  Printf.printf "\n%s\n" (P0_duckdb.duckdb_api_survey ());
  Printf.printf "\n=== P0 probe completed successfully ===\n"
