module S = Sqlite_fast_direct.Direct_sqlite

let fail label =
  failwith ("p3_failure_smoke: " ^ label)

let with_db f =
  let db = S.open_memory () in
  Fun.protect
    ~finally:(fun () -> ignore (S.close db))
    (fun () -> f db)

let expect_message_contains label needle f =
  match f () with
  | _ -> fail (label ^ ": expected Failure")
  | exception Failure message ->
      if not (String.contains message needle) then
        fail (label ^ ": unexpected message: " ^ message)

let test_bind_range db =
  let stmt = S.prepare db "SELECT ?" in
  S.expect_rc "bind index zero" S.range (S.bind_int stmt 0 1);
  S.expect_rc "bind index too high" S.range (S.bind_int stmt 2 1);
  S.expect_ok "bind valid index" (S.bind_int stmt 1 7);
  S.expect_row "step valid bound statement" (S.step stmt);
  if S.column_int stmt 0 <> 7 then
    fail "valid bind did not roundtrip";
  S.expect_done "drain valid bound statement" (S.step stmt);
  S.expect_ok "finalize bind range stmt" (S.finalize stmt)

let test_constraint_failure db =
  S.exec db "CREATE TABLE unique_items (id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL)";
  S.exec db "INSERT INTO unique_items (name) VALUES ('same')";
  let dup = S.prepare db "INSERT INTO unique_items (name) VALUES (?)" in
  S.expect_ok "bind duplicate name" (S.bind_text dup 1 "same");
  S.expect_rc "duplicate insert step" S.constraint_ (S.step dup);
  S.expect_rc "reset preserves duplicate failure" S.constraint_ (S.reset dup);
  S.expect_ok "clear duplicate bindings" (S.clear_bindings dup);
  S.expect_ok "bind distinct name" (S.bind_text dup 1 "other");
  S.expect_done "insert after reset failure" (S.step dup);
  S.expect_ok "finalize duplicate stmt" (S.finalize dup);
  let count = S.query_one_int db "SELECT COUNT(*) FROM unique_items" in
  if count <> 2 then
    fail ("constraint recovery count expected 2 got " ^ string_of_int count)

let test_closed_database_failure () =
  let db = S.open_memory () in
  S.expect_ok "close before prepare" (S.close db);
  expect_message_contains "prepare closed db" 'c' (fun () ->
    ignore (S.prepare db "SELECT 1"))

let test_finalize_after_failed_prepare db =
  expect_message_contains "invalid SQL" 's' (fun () ->
    ignore (S.prepare db "SELECT FROM"));
  S.exec db "CREATE TABLE after_invalid_sql (id INTEGER PRIMARY KEY)";
  let count = S.query_one_int db "SELECT COUNT(*) FROM after_invalid_sql" in
  if count <> 0 then
    fail "database unusable after invalid SQL"

let () =
  with_db (fun db ->
    test_bind_range db;
    test_constraint_failure db;
    test_finalize_after_failed_prepare db);
  test_closed_database_failure ();
  print_endline "p3_failure_smoke PASS"

