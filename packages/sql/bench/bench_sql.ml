module Q = Sql
module S = Sqlite

module Users = struct
  module T = Q.Table.Make (struct
    let name = "users"
  end)

  include T

  let id = column "id" Q.int
  let name = column "name" Q.text
  let active = column "active" Q.bool
  let nickname = column "nickname" (Q.nullable Q.text)
end

let expect_ok = function
  | Ok value -> value
  | Error err -> failwith (Q.show_error err)

let repeat n f =
  for i = 1 to n do
    f i
  done

let select_query () =
  Q.Select.(
    from Users.table Q.Projection.(t3 Users.id Users.name Users.nickname)
    |> where Q.Expr.(and_ (gt Users.id 10) (like Users.name "A%"))
    |> order_by ~desc:true Users.name
    |> limit 10)

let render_select () =
  ignore (Q.Select.to_sql (select_query ()))

let compile_insert () =
  ignore
    Q.Insert.(
      into Users.table
      |> value Users.name "Ada"
      |> value Users.active true
      |> value Users.nickname None
      |> compile)

let render_schema () =
  ignore
    Q.Schema.(
      create_table Users.table
        [
          column ~primary_key:true Users.id;
          column ~not_null:true Users.name;
          column ~not_null:true Users.active;
          column Users.nickname;
        ]
      |> to_sql)

let sqlite_roundtrip rows =
  let conn = Q.Connection.create (S.memory_config ()) |> expect_ok in
  Fun.protect
    ~finally:(fun () -> Q.Connection.close conn)
    (fun () ->
      Q.Connection.run_schema conn
        Q.Schema.(
          create_table Users.table
            [
              column ~primary_key:true Users.id;
              column ~not_null:true Users.name;
              column ~not_null:true Users.active;
              column Users.nickname;
            ]
          |> compile)
      |> expect_ok;
      repeat rows (fun i ->
          ignore
            (Q.Connection.execute_compiled conn
               Q.Insert.(
                 into Users.table
                 |> value Users.name ("user-" ^ string_of_int i)
                 |> value Users.active (i land 1 = 0)
                 |> value Users.nickname None
                 |> compile)
            |> expect_ok));
      ignore
        (Q.Connection.select conn (Q.Select.compile (select_query ()))
        |> expect_ok))

let check_sqlite db operation rc =
  match S.check db ~operation rc with
  | Ok () -> ()
  | Error err -> failwith (Format.asprintf "%a" S.pp_error err)

let check_row operation rc =
  if not (S.rc_equal rc S.row) then
    failwith (operation ^ ": expected ROW, got " ^ S.rc_name rc)

let check_done operation rc =
  if not (S.rc_equal rc S.done_) then
    failwith (operation ^ ": expected DONE, got " ^ S.rc_name rc)

let cleanup_sqlite_path path =
  List.iter
    (fun suffix ->
      let path = path ^ suffix in
      if Sys.file_exists path then Sys.remove path)
    [ ""; "-wal"; "-shm" ]

let create_sqlite_table db =
  S.exec db
    "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, active INTEGER NOT NULL)"

let seed_sqlite_prepared db rows =
  create_sqlite_table db;
  S.begin_transaction db;
  let insert =
    S.prepare db "INSERT INTO users (id, name, active) VALUES (?, ?, ?)"
  in
  Fun.protect
    ~finally:(fun () -> ignore (S.finalize insert))
    (fun () ->
      repeat rows (fun i ->
          check_sqlite db "bind id" (S.bind_int insert 1 i);
          check_sqlite db "bind name" (S.bind_text insert 2 ("user-" ^ string_of_int i));
          check_sqlite db "bind active" (S.bind_int insert 3 (i land 1));
          check_done "insert" (S.step insert);
          check_sqlite db "reset insert" (S.reset insert);
          check_sqlite db "clear insert" (S.clear_bindings insert)));
  S.commit db

let sqlite_prepare_finalize loops =
  let db = S.open_memory () in
  Fun.protect
    ~finally:(fun () -> ignore (S.close db))
    (fun () ->
      repeat loops (fun _ ->
          let stmt = S.prepare db "SELECT 1" in
          check_row "select one" (S.step stmt);
          ignore (S.column_int stmt 0);
          check_done "drain select one" (S.step stmt);
          check_sqlite db "finalize select one" (S.finalize stmt)))

let sqlite_prepared_insert_tx rows =
  let db = S.open_memory () in
  Fun.protect
    ~finally:(fun () -> ignore (S.close db))
    (fun () ->
      seed_sqlite_prepared db rows;
      let count = S.query_one_int db "SELECT COUNT(*) FROM users" in
      assert (count = rows))

let sqlite_prepared_point_lookup ~rows ~lookups =
  let db = S.open_memory () in
  Fun.protect
    ~finally:(fun () -> ignore (S.close db))
    (fun () ->
      seed_sqlite_prepared db rows;
      let query = S.prepare db "SELECT name FROM users WHERE id = ?" in
      Fun.protect
        ~finally:(fun () -> ignore (S.finalize query))
        (fun () ->
          let total = ref 0 in
          repeat lookups (fun i ->
              let id = ((i - 1) mod rows) + 1 in
              check_sqlite db "bind lookup id" (S.bind_int query 1 id);
              check_row "lookup" (S.step query);
              total := !total + String.length (S.column_text query 0);
              check_done "drain lookup" (S.step query);
              check_sqlite db "reset lookup" (S.reset query);
              check_sqlite db "clear lookup" (S.clear_bindings query));
          assert (!total > 0)))

let sqlite_scan rows =
  let db = S.open_memory () in
  Fun.protect
    ~finally:(fun () -> ignore (S.close db))
    (fun () ->
      seed_sqlite_prepared db rows;
      let query = S.prepare db "SELECT id, name, active FROM users ORDER BY id" in
      Fun.protect
        ~finally:(fun () -> ignore (S.finalize query))
        (fun () ->
          let count = ref 0 in
          let checksum = ref 0 in
          let rec loop () =
            let rc = S.step query in
            if S.rc_equal rc S.row then begin
              incr count;
              checksum :=
                !checksum + S.column_int query 0
                + String.length (S.column_text query 1)
                + S.column_int query 2;
              loop ()
            end
            else
              check_done "scan" rc
          in
          loop ();
          assert (!count = rows);
          assert (!checksum > 0)))

let sqlite_connection_select rows =
  let conn = Q.Connection.create (S.memory_config ()) |> expect_ok in
  Fun.protect
    ~finally:(fun () -> Q.Connection.close conn)
    (fun () ->
      Q.Connection.run_schema conn
        Q.Schema.(
          create_table Users.table
            [
              column ~primary_key:true Users.id;
              column ~not_null:true Users.name;
              column ~not_null:true Users.active;
              column Users.nickname;
            ]
          |> compile)
      |> expect_ok;
      Q.Connection.begin_transaction conn |> expect_ok;
      repeat rows (fun i ->
          ignore
            (Q.Connection.execute_compiled conn
               Q.Insert.(
                 into Users.table
                 |> value Users.id i
                 |> value Users.name ("user-" ^ string_of_int i)
                 |> value Users.active (i land 1 = 0)
                 |> value Users.nickname None
                 |> compile)
            |> expect_ok));
      Q.Connection.commit conn |> expect_ok;
      let rows =
        Q.Connection.select conn
          Q.Select.(
            from Users.table Q.Projection.(t3 Users.id Users.name Users.active)
            |> order_by Users.id
            |> compile)
        |> expect_ok
      in
      assert (List.length rows > 0))

let sqlite_file_wal_insert_tx rows =
  let path = Filename.temp_file "eta-sql-bench-" ".db" in
  cleanup_sqlite_path path;
  Fun.protect
    ~finally:(fun () -> cleanup_sqlite_path path)
    (fun () ->
      let config =
        {
          (S.default_config path) with
          journal_mode = Some `Wal;
          synchronous = Some `Normal;
          cache_size = Some (-8_000);
        }
      in
      S.with_db config @@ fun db ->
      seed_sqlite_prepared db rows;
      assert (S.query_one_int db "SELECT COUNT(*) FROM users" = rows))

let workloads =
  let item name run =
    { Bench_lib.name = "sql." ^ name; run; samples = None }
  in
  [
    item "select.render.100k" (fun () -> repeat 100_000 (fun _ -> render_select ()));
    item "insert.compile.100k" (fun () -> repeat 100_000 (fun _ -> compile_insert ()));
    item "schema.render.100k" (fun () -> repeat 100_000 (fun _ -> render_schema ()));
    item "sqlite.memory_roundtrip.100" (fun () -> sqlite_roundtrip 100);
    item "sqlite.prepare_finalize.10k" (fun () -> sqlite_prepare_finalize 10_000);
    item "sqlite.prepared_insert_tx.1k" (fun () -> sqlite_prepared_insert_tx 1_000);
    item "sqlite.prepared_point_lookup.10k" (fun () ->
        sqlite_prepared_point_lookup ~rows:1_000 ~lookups:10_000);
    item "sqlite.scan.10k" (fun () -> sqlite_scan 10_000);
    item "sqlite.connection_select.1k" (fun () -> sqlite_connection_select 1_000);
    item "sqlite.file_wal_insert_tx.1k" (fun () -> sqlite_file_wal_insert_tx 1_000);
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
