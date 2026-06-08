let () =
  Printf.printf "sqlite_version=%s\n" (Sqlite_fast_p0.P0_sqlite.sqlite_version ());
  Printf.printf "%s\n" (Sqlite_fast_p0.P0_sqlite.sqlite_smoke ())
