module S = Sqlite_fast_direct.Direct_sqlite

let fail label =
  failwith ("p1_direct_smoke: " ^ label)

let expect_int label ~expected actual =
  if actual <> expected then
    fail
      (label ^ ": expected " ^ string_of_int expected ^ ", got " ^ string_of_int actual)

let expect_string label ~expected actual =
  if actual <> expected then
    fail
      (label ^ ": expected " ^ expected ^ ", got " ^ actual)

let expect_prepare_failure db =
  match S.prepare db "SELECT FROM" with
  | _ -> fail "invalid SQL prepared successfully"
  | exception Failure message ->
      if not (String.contains message 's') then
        fail ("unexpected invalid SQL message: " ^ message)

let with_db f =
  let db = S.open_memory () in
  Fun.protect
    ~finally:(fun () -> ignore (S.close db))
    (fun () -> f db)

let smoke_success_path db =
  S.exec db "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)";
  let insert = S.prepare db "INSERT INTO users (name) VALUES (?)" in
  S.expect_rc "insert parameter count" 1 (S.bind_parameter_count insert);
  S.expect_ok "bind Ada" (S.bind_text insert 1 "Ada");
  S.expect_done "insert Ada" (S.step insert);
  S.expect_ok "reset insert" (S.reset insert);
  S.expect_ok "clear insert" (S.clear_bindings insert);
  S.expect_ok "bind Grace" (S.bind_text insert 1 "Grace");
  S.expect_done "insert Grace" (S.step insert);
  S.expect_ok "finalize insert" (S.finalize insert);
  expect_int "changes" ~expected:1 (S.changes db);
  let query = S.prepare db "SELECT id, name FROM users WHERE id = ?" in
  S.expect_ok "bind query id" (S.bind_int query 1 2);
  S.expect_row "select Grace" (S.step query);
  expect_int "selected id" ~expected:2 (S.column_int query 0);
  expect_string "selected name" ~expected:"Grace" (S.column_text query 1);
  S.expect_done "select drain" (S.step query);
  S.expect_ok "finalize query" (S.finalize query)

let smoke_transaction_rollback db =
  S.exec db "BEGIN";
  S.exec db "INSERT INTO users (name) VALUES ('rolled back')";
  S.exec db "ROLLBACK";
  let count = S.query_one_int db "SELECT COUNT(*) FROM users" in
  expect_int "rollback count" ~expected:2 count

let smoke_lifecycle_edges db =
  let stmt = S.prepare db "SELECT 1" in
  S.expect_ok "finalize once" (S.finalize stmt);
  S.expect_ok "finalize twice" (S.finalize stmt);
  S.expect_rc "reset finalized stmt" S.misuse (S.reset stmt);
  let live_stmt = S.prepare db "SELECT 1" in
  S.expect_ok "close with live stmt" (S.close db);
  S.expect_ok "finalize after db close" (S.finalize live_stmt);
  S.expect_ok "close twice" (S.close db)

let () =
  with_db (fun db ->
    smoke_success_path db;
    smoke_transaction_rollback db;
    expect_prepare_failure db);
  with_db smoke_lifecycle_edges;
  print_endline "p1_direct_smoke PASS"

