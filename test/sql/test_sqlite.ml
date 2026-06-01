module S = Eta_sql.Sqlite

let rc =
  Alcotest.testable
    (fun ppf rc -> Format.pp_print_string ppf (S.rc_name rc))
    S.rc_equal

let check_rc label expected actual =
  Alcotest.check rc label expected actual

let check_ok label actual = check_rc label S.ok actual
let check_done label actual = check_rc label S.done_ actual
let check_row label actual = check_rc label S.row actual

let with_db f =
  let db = S.open_memory () in
  Fun.protect
    ~finally:(fun () -> ignore (S.close db))
    (fun () -> f db)

let contains haystack needle =
  let h_len = String.length haystack in
  let n_len = String.length needle in
  let rec at pos i =
    i = n_len
    || (pos + i < h_len
       && Char.equal haystack.[pos + i] needle.[i]
       && at pos (i + 1))
  in
  let rec loop pos =
    n_len = 0
    || (pos + n_len <= h_len && (at pos 0 || loop (pos + 1)))
  in
  loop 0

let test_sqlite_memory_prepare_bind_scan () =
  with_db @@ fun db ->
  S.exec db "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)";
  let insert = S.prepare db "INSERT INTO users (name) VALUES (?)" in
  Alcotest.(check int) "parameter count" 1 (S.bind_parameter_count insert);
  check_ok "bind Ada" (S.bind_text insert 1 "Ada");
  check_done "insert Ada" (S.step insert);
  check_ok "reset insert" (S.reset insert);
  check_ok "clear insert" (S.clear_bindings insert);
  check_ok "bind Grace" (S.bind_text insert 1 "Grace");
  check_done "insert Grace" (S.step insert);
  check_ok "finalize insert" (S.finalize insert);
  Alcotest.(check int) "changes" 1 (S.changes db);
  S.exec db "INSERT INTO users (name) VALUES ('Null probe')";
  let null_query = S.prepare db "SELECT NULL FROM users LIMIT 1" in
  check_row "select null" (S.step null_query);
  Alcotest.(check bool) "null column" true (S.column_is_null null_query 0);
  check_ok "finalize null query" (S.finalize null_query);
  let query = S.prepare db "SELECT id, name FROM users WHERE id = ?" in
  check_ok "bind query id" (S.bind_int query 1 2);
  check_row "select Grace" (S.step query);
  Alcotest.(check int) "selected id" 2 (S.column_int query 0);
  Alcotest.(check string) "selected name" "Grace" (S.column_text query 1);
  check_done "select drain" (S.step query);
  check_ok "finalize query" (S.finalize query)

let test_sqlite_structured_prepare_error () =
  with_db @@ fun db ->
  match S.prepare_result db "SELECT FROM" with
  | Ok _ -> Alcotest.fail "invalid SQL prepared successfully"
  | Error err ->
      Alcotest.(check string) "operation" "prepare" err.operation;
      Alcotest.(check bool) "message mentions prepare" true
        (contains err.message "sqlite prepare")

let test_sqlite_range_and_constraint_errors () =
  with_db @@ fun db ->
  S.exec db "CREATE TABLE uniq (id INTEGER PRIMARY KEY, name TEXT UNIQUE)";
  let insert = S.prepare db "INSERT INTO uniq (id, name) VALUES (?, ?)" in
  check_ok "bind id" (S.bind_int insert 1 1);
  check_ok "bind name" (S.bind_text insert 2 "Ada");
  check_done "insert first" (S.step insert);
  check_ok "reset first" (S.reset insert);
  check_ok "clear first" (S.clear_bindings insert);
  check_rc "out of range bind" S.range (S.bind_int insert 3 10);
  check_ok "bind duplicate id" (S.bind_int insert 1 2);
  check_ok "bind duplicate name" (S.bind_text insert 2 "Ada");
  check_rc "duplicate unique" S.constraint_ (S.step insert);
  check_rc "reset duplicate" S.constraint_ (S.reset insert);
  check_ok "clear duplicate" (S.clear_bindings insert);
  check_ok "bind second id" (S.bind_int insert 1 2);
  check_ok "bind second name" (S.bind_text insert 2 "Grace");
  check_done "insert second" (S.step insert);
  check_ok "finalize insert" (S.finalize insert);
  Alcotest.(check int) "row count" 2 (S.query_one_int db "SELECT COUNT(*) FROM uniq")

let test_sqlite_column_int_rejects_out_of_ocaml_range () =
  with_db @@ fun db ->
  let stmt = S.prepare db "SELECT 4611686018427387904" in
  Fun.protect
    ~finally:(fun () -> check_ok "finalize range query" (S.finalize stmt))
    (fun () ->
      check_row "select oversized int" (S.step stmt);
      Alcotest.check_raises "column_int range"
        (Invalid_argument "Eta_sql.Sqlite.column_int: SQLite integer outside OCaml int range")
        (fun () -> ignore (S.column_int stmt 0)))

let test_sqlite_close_with_live_statement () =
  let db = S.open_memory () in
  let stmt = S.prepare db "SELECT 1" in
  check_ok "close with live stmt" (S.close db);
  check_ok "finalize after close" (S.finalize stmt);
  check_ok "finalize twice" (S.finalize stmt);
  check_rc "reset finalized stmt" S.misuse (S.reset stmt);
  check_ok "close twice" (S.close db)

let test_sqlite_path_and_read_only_mode () =
  let path = Filename.temp_file "eta-sqlite-" ".db" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists path then
        Sys.remove path)
    (fun () ->
      let db = S.open_ path in
      S.exec db "CREATE TABLE items (id INTEGER PRIMARY KEY)";
      S.exec db "INSERT INTO items (id) VALUES (1)";
      check_ok "close write db" (S.close db);
      let ro = S.open_ ~mode:S.Read_only path in
      Fun.protect
        ~finally:(fun () -> ignore (S.close ro))
        (fun () ->
          Alcotest.(check int) "readonly count" 1
            (S.query_one_int ro "SELECT COUNT(*) FROM items");
          match S.exec_result ro "INSERT INTO items (id) VALUES (2)" with
          | Ok () -> Alcotest.fail "readonly insert unexpectedly succeeded"
          | Error err ->
              Alcotest.(check string) "readonly operation" "exec" err.operation;
              Alcotest.(check bool) "readonly is not ok" false
                (S.rc_equal S.ok err.code)))

let test_sqlite_config_exec_script_and_pragmas () =
  let config =
    {
      (S.memory_config ()) with
      busy_timeout_ms = Some 250;
      foreign_keys = true;
      synchronous = Some `Off;
      cache_size = Some (-2_000);
    }
  in
  S.with_db config @@ fun db ->
  S.exec_script db
    "CREATE TABLE parent (id INTEGER PRIMARY KEY);
     CREATE TABLE child (parent_id INTEGER REFERENCES parent(id));
     INSERT INTO parent (id) VALUES (1);
     INSERT INTO child (parent_id) VALUES (1);";
  Alcotest.(check int) "parent count" 1
    (S.query_one_int db "SELECT COUNT(*) FROM parent");
  Alcotest.(check int) "foreign keys enabled" 1
    (S.query_one_int db "PRAGMA foreign_keys");
  Alcotest.(check bool) "complete sql" true (S.complete "SELECT 1;");
  Alcotest.(check bool) "incomplete sql" false (S.complete "SELECT 1")

let test_sqlite_transactions_and_savepoints () =
  with_db @@ fun db ->
  S.exec db "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)";
  S.with_transaction db (fun db ->
      S.exec db "INSERT INTO items (name) VALUES ('committed')");
  Alcotest.(check int) "committed" 1
    (S.query_one_int db "SELECT COUNT(*) FROM items");
  ignore
    (S.with_transaction_result db @@ fun db ->
     S.exec db "INSERT INTO items (name) VALUES ('rolled back')";
     Error { operation = "probe"; code = S.misuse; message = "force rollback" });
  Alcotest.(check int) "rolled back" 1
    (S.query_one_int db "SELECT COUNT(*) FROM items");
  S.begin_transaction db;
  S.savepoint db "nested";
  S.exec db "INSERT INTO items (name) VALUES ('savepoint')";
  S.rollback_to db "nested";
  S.release db "nested";
  S.commit db;
  Alcotest.(check int) "savepoint rolled back" 1
    (S.query_one_int db "SELECT COUNT(*) FROM items");
  Alcotest.(check bool) "autocommit restored" true (S.autocommit db)

let test_sqlite_transaction_commit_failure_rolls_back () =
  S.with_db (S.memory_config ()) @@ fun db ->
  S.exec_script db
    "CREATE TABLE parent (id INTEGER PRIMARY KEY);
     CREATE TABLE child (
       parent_id INTEGER,
       FOREIGN KEY(parent_id) REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED
     );";
  (match
     S.with_transaction_result db (fun db ->
         S.exec db "INSERT INTO child (parent_id) VALUES (42)";
         Ok ())
   with
  | Ok () -> Alcotest.fail "commit unexpectedly accepted deferred FK violation"
  | Error err ->
      Alcotest.(check string) "commit operation" "exec" err.operation);
  Alcotest.(check bool) "autocommit restored" true (S.autocommit db);
  S.with_transaction db (fun db ->
      S.exec db "INSERT INTO parent (id) VALUES (1)");
  Alcotest.(check int) "only committed parent" 1
    (S.query_one_int db "SELECT COUNT(*) FROM parent");
  Alcotest.(check int) "failed child rolled back" 0
    (S.query_one_int db "SELECT COUNT(*) FROM child")

let test_sqlite_float_blob_metadata_and_counters () =
  with_db @@ fun db ->
  S.exec db "CREATE TABLE values_ (id INTEGER PRIMARY KEY, n REAL, b BLOB, z BLOB)";
  let insert = S.prepare db "INSERT INTO values_ (n, b, z) VALUES (?, ?, ?)" in
  check_ok "bind float" (S.bind_float insert 1 3.5);
  check_ok "bind blob" (S.bind_blob insert 2 (Bytes.of_string "abc"));
  check_ok "bind zeroblob" (S.bind_zeroblob insert 3 4);
  check_done "insert typed values" (S.step insert);
  check_ok "finalize typed insert" (S.finalize insert);
  Alcotest.(check int64) "last insert rowid" 1L (S.last_insert_rowid db);
  Alcotest.(check int) "total changes" 1 (S.total_changes db);
  let query = S.prepare db "SELECT n AS n_alias, b, z FROM values_ WHERE id = ?" in
  Alcotest.(check bool) "statement readonly" true (S.statement_readonly query);
  Alcotest.(check string) "statement sql"
    "SELECT n AS n_alias, b, z FROM values_ WHERE id = ?" (S.statement_sql query);
  check_ok "bind query id" (S.bind_int query 1 1);
  Alcotest.(check bool) "expanded has value" true
    (contains (S.expanded_sql query) "id = 1");
  check_row "select typed values" (S.step query);
  Alcotest.(check int) "column count" 3 (S.column_count query);
  Alcotest.(check int) "data count" 3 (S.data_count query);
  Alcotest.(check string) "column alias" "n_alias" (S.column_name query 0);
  Alcotest.(check int) "float type" S.sqlite_float (S.column_type_code query 0);
  Alcotest.(check int) "blob type" S.sqlite_blob (S.column_type_code query 1);
  Alcotest.(check (float 0.0001)) "float value" 3.5 (S.column_float query 0);
  Alcotest.(check bytes) "blob value" (Bytes.of_string "abc") (S.column_blob query 1);
  Alcotest.(check int) "zeroblob length" 4 (Bytes.length (S.column_blob query 2));
  Alcotest.(check bool) "statement busy after row" true (S.statement_busy query);
  check_done "drain typed values" (S.step query);
  check_ok "finalize typed query" (S.finalize query)

let test_sqlite_backup_and_restore () =
  let backup_path = Filename.temp_file "eta-sqlite-backup-" ".db" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists backup_path then
        Sys.remove backup_path)
    (fun () ->
      with_db @@ fun db ->
      S.exec db "CREATE TABLE items (id INTEGER PRIMARY KEY)";
      S.exec db "INSERT INTO items (id) VALUES (1), (2)";
      S.backup_to_path db backup_path;
      S.exec db "DELETE FROM items";
      Alcotest.(check int) "deleted" 0
        (S.query_one_int db "SELECT COUNT(*) FROM items");
      S.restore_from_path db backup_path;
      Alcotest.(check int) "restored" 2
        (S.query_one_int db "SELECT COUNT(*) FROM items"))

let process_cpu_seconds () =
  let t = Unix.times () in
  t.Unix.tms_utime +. t.tms_stime +. t.tms_cutime +. t.tms_cstime

let test_sqlite_backup_waits_without_busy_spinning () =
  let source_path = Filename.temp_file "eta-sqlite-source-" ".db" in
  let backup_path = Filename.temp_file "eta-sqlite-backup-" ".db" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists source_path then
        Sys.remove source_path;
      if Sys.file_exists backup_path then
        Sys.remove backup_path)
    (fun () ->
      let setup = S.open_ source_path in
      Fun.protect
        ~finally:(fun () -> ignore (S.close setup))
        (fun () ->
          S.exec setup "CREATE TABLE items (id INTEGER PRIMARY KEY)";
          S.exec setup "INSERT INTO items (id) VALUES (1)");
      let locker = S.open_ source_path in
      let source = S.open_ source_path in
      Fun.protect
        ~finally:(fun () ->
          ignore (S.close source);
          ignore (S.close locker))
        (fun () ->
          S.exec locker "BEGIN EXCLUSIVE";
          S.exec locker "INSERT INTO items (id) VALUES (2)";
          let releaser =
            Thread.create
              (fun () ->
                Thread.delay 0.15;
                S.exec locker "COMMIT")
              ()
          in
          let cpu_before = process_cpu_seconds () in
          let wall_before = Unix.gettimeofday () in
          let result = S.backup_to_path_result source backup_path in
          let wall_elapsed = Unix.gettimeofday () -. wall_before in
          let cpu_elapsed = process_cpu_seconds () -. cpu_before in
          Thread.join releaser;
          (match result with
           | Ok () -> ()
           | Error err ->
               Alcotest.failf "backup failed while waiting for lock: %a"
                 S.pp_error err);
          Alcotest.(check bool) "backup waited for the lock" true
            (wall_elapsed >= 0.10);
          Alcotest.(check bool) "backup did not busy spin" true
            (cpu_elapsed < 0.06)))

let test_sqlite_load_extension_toggle () =
  with_db @@ fun db ->
  check_ok "enable extension loading" (S.enable_load_extension db true);
  check_ok "disable extension loading" (S.enable_load_extension db false)

let test_sqlite_config_error_and_testing_helpers () =
  let result =
    S.Testing.with_db (S.Config.in_memory ()) @@ fun db ->
    S.exec db "CREATE TABLE items (id INTEGER PRIMARY KEY)";
    S.exec db "INSERT INTO items (id) VALUES (1)";
    Ok (S.query_one_int db "SELECT COUNT(*) FROM items")
  in
  Alcotest.(check (result int string)) "testing helper" (Ok 1) result;
  let message =
    S.Error.to_string { operation = "probe"; code = S.ok; message = "ok" }
  in
  Alcotest.(check bool) "error string contains operation" true
    (contains message "probe");
  Alcotest.(check string) "busy rc name" "BUSY" (S.rc_name S.busy);
  Alcotest.(check string) "interrupt rc name" "INTERRUPT" (S.rc_name S.interrupt_)

let test_sqlite_unexpected_step_success_is_typed_error () =
  match Eta_sql__Types.unexpected_sqlite_step ~operation:"query" S.ok with
  | Error (Eta_sql.Sqlite err) ->
      Alcotest.(check string) "operation" "query" err.operation;
      check_ok "code" err.code;
      Alcotest.(check bool) "message names unexpected" true
        (contains err.message "unexpected SQLite step result OK")
  | Error err ->
      Alcotest.failf "expected SQLite error, got %s" (Eta_sql.show_error err)
  | Ok () -> Alcotest.fail "unexpected step success returned Ok"
