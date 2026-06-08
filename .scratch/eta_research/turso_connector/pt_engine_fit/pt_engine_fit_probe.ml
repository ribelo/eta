module _ : Engine.S = Pt_engine_fit

module E = Pt_engine_fit

let require label = function
  | Ok value -> value
  | Error err ->
      Printf.eprintf "%s failed: %s\n" label (E.Error.to_string err);
      exit 1

let () =
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      ("eta_turso_pt_engine_fit_" ^ string_of_int (Unix.getpid ()) ^ ".db")
  in
  (try Sys.remove path with Sys_error _ -> ());
  Printf.printf "=== P-Turso-1 ENGINE fit smoke ===\n";
  Printf.printf "database=%s\n" path;
  Printf.printf "engine_signature=compiled module constraint Engine.S\n";
  Printf.printf "column_int_strategy=sqlite3_column_int64 plus OCaml-side cast if needed\n";
  let db = require "open_database" (E.open_database path) in
  let conn = require "connect" (E.connect db) in
  require "exec create"
    (E.exec conn
       "CREATE TABLE smoke (id INTEGER PRIMARY KEY, name TEXT NOT NULL, n INTEGER);");
  let stmt =
    require "prepare insert"
      (E.prepare conn "INSERT INTO smoke (name, n) VALUES (?, ?)")
  in
  require "bind name" (E.bind stmt 1 (E.Value.String "turso"));
  require "bind n" (E.bind stmt 2 (E.Value.Int 42));
  let inserted = require "step insert" (E.step stmt) in
  require "finalize insert" (E.finalize stmt);
  Printf.printf "insert_step_has_row=%b\n" inserted;
  let stmt =
    require "prepare select"
      (E.prepare conn "SELECT id, name, n FROM smoke ORDER BY id")
  in
  let has_row = require "step select" (E.step stmt) in
  let id = E.column_int64 stmt 0 in
  let name = E.column_text stmt 1 in
  let n = E.column_int64 stmt 2 in
  Printf.printf "select_has_row=%b id=%Ld name=%s n=%Ld\n" has_row id name n;
  require "finalize select" (E.finalize stmt);
  require "disconnect" (E.disconnect conn);
  require "close_database" (E.close_database db);
  (try Sys.remove path with Sys_error _ -> ());
  let ok = (not inserted) && has_row && id = 1L && String.equal name "turso" && n = 42L in
  Printf.printf "verdict=%s\n" (if ok then "Confirmed" else "Falsified");
  if not ok then exit 1
