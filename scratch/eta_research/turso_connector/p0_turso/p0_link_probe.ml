(** P0 Turso link probe — confirms libturso_sqlite3 is reachable and functional. *)

let () =
  Printf.printf "=== P0 Turso Link Probe ===\n\n";
  Printf.printf "turso_version=%s\n" (P0_turso.turso_version ());
  Printf.printf "%s\n" (P0_turso.turso_smoke ());
  Printf.printf "\n%s\n" (P0_turso.turso_api_survey ());
  Printf.printf "\n=== P0 probe completed successfully ===\n"
