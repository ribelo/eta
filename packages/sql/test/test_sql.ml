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

module Posts = struct
  module T = Q.Table.Make (struct
    let name = "posts"
  end)

  include T

  let id = column "id" Q.int
  let author_id = column "author_id" Q.int
  let title = column "title" Q.text
end

module ActiveUsers = struct
  module T = Q.Table.Make (struct
    let name = "active_users"
  end)

  include T

  let id = column "id" Q.int
  let name = column "name" Q.text
end

let sql_ok = function
  | Ok value -> value
  | Error err -> Alcotest.failf "%a" Q.pp_error err

let migrate_ok = function
  | Ok value -> value
  | Error err -> Alcotest.failf "%s" (Q.Migrate.error_to_string err)

let pool_stat stats = function
  | `Total ->
      List.find_map
        (function Q.Pool.Total_connections value -> Some value | _ -> None)
        stats
  | `Available ->
      List.find_map
        (function Q.Pool.Available_connections value -> Some value | _ -> None)
        stats
  | `In_use ->
      List.find_map
        (function Q.Pool.In_use_connections value -> Some value | _ -> None)
        stats
  | `Waiting ->
      List.find_map
        (function Q.Pool.Waiting_requests value -> Some value | _ -> None)
        stats

let select_all conn query =
  Q.Connection.select conn (Q.Select.compile query) |> sql_ok

let select_find_opt_result conn query =
  match Q.Connection.select conn (Q.Select.compile query) with
  | Error _ as err -> err
  | Ok [] -> Ok None
  | Ok [ row ] -> Ok (Some row)
  | Ok _ ->
      Error
        (Q.Decode_error
           { operation = "find_opt"; message = "query returned more than one row" })

let execute_compiled conn query =
  Q.Connection.execute_compiled conn query |> sql_ok

let run_schema conn schema =
  Q.Connection.run_schema conn (Q.Schema.compile schema) |> sql_ok

let with_db f =
  let conn = Q.Connection.create (S.memory_config ()) |> sql_ok in
  Fun.protect
    ~finally:(fun () -> Q.Connection.close conn)
    (fun () ->
      Q.Schema.(
        create_table Users.table
          [
            column ~primary_key:true Users.id;
            column ~not_null:true Users.name;
            column ~not_null:true Users.active;
            column Users.nickname;
          ])
      |> run_schema conn;
      f conn)

let seed db =
  ignore
    (Q.Insert.(
       into Users.table
       |> value Users.name "Ada"
       |> value Users.active true
       |> value Users.nickname None
       |> compile)
    |> execute_compiled db);
  ignore
    (Q.Insert.(
       into Users.table
       |> value Users.name "Grace"
       |> value Users.active true
       |> value Users.nickname (Some "Amazing")
       |> compile)
    |> execute_compiled db);
  ignore
    (Q.Insert.(
       into Users.table
       |> value Users.name "Inactive"
       |> value Users.active false
       |> value Users.nickname None
       |> compile)
    |> execute_compiled db)

let test_sql_select_insert_update_delete () =
  with_db @@ fun db ->
  seed db;
  let active_users =
    Q.Select.(
      from Users.table Q.Projection.(t3 Users.id Users.name Users.nickname)
      |> where Q.Expr.(eq Users.active true)
      |> order_by Users.id
      |> select_all db)
  in
  Alcotest.(check (list (triple int string (option string))))
    "active users"
    [ (1, "Ada", None); (2, "Grace", Some "Amazing") ]
    active_users;
  let changed =
    Q.Update.(
      table Users.table
      |> set Users.nickname (Some "Countess")
      |> where Q.Expr.(eq Users.name "Ada")
      |> compile |> execute_compiled db)
  in
  Alcotest.(check int) "updated rows" 1 changed;
  let ada =
    Q.Select.(
      from Users.table Q.Projection.(t2 Users.name Users.nickname)
      |> where Q.Expr.(eq Users.id 1)
      |> select_find_opt_result db |> Result.get_ok)
  in
  Alcotest.(check (option (pair string (option string))))
    "updated Ada" (Some ("Ada", Some "Countess")) ada;
  let deleted =
    Q.Delete.(from Users.table |> where Q.Expr.(eq Users.active false) |> compile |> execute_compiled db)
  in
  Alcotest.(check int) "deleted rows" 1 deleted;
  let remaining =
    Q.Select.(from Users.table Q.Projection.(one Users.id) |> order_by Users.id |> select_all db)
  in
  Alcotest.(check (list int)) "remaining ids" [ 1; 2 ] remaining

let test_sql_render_stable_sql () =
  let query =
    Q.Select.(
      from Users.table Q.Projection.(t2 Users.id Users.name)
      |> where Q.Expr.(and_ (gt Users.id 10) (like Users.name "A%"))
      |> order_by ~desc:true Users.name
      |> limit 1)
  in
  Alcotest.(check string) "rendered select"
    "SELECT \"users\".\"id\", \"users\".\"name\" FROM \"users\" WHERE (\"users\".\"id\" > ? AND \"users\".\"name\" LIKE ?) ORDER BY \"users\".\"name\" DESC LIMIT 1"
    (Q.Select.to_sql query)

let test_sql_select_aggregates_distinct_group () =
  with_db @@ fun db ->
  seed db;
  let active_count =
    Q.Select.(
      from Users.table Q.Projection.(count ())
      |> where Q.Expr.(eq Users.active true)
      |> select_all db)
  in
  Alcotest.(check (list int)) "active count" [ 2 ] active_count;
  let active_id_sum =
    Q.Select.(
      from Users.table Q.Projection.(sum_int Users.id)
      |> where Q.Expr.(eq Users.active true)
      |> select_all db)
  in
  Alcotest.(check (list int)) "active id sum" [ 3 ] active_id_sum;
  let distinct_active =
    Q.Select.(
      from Users.table Q.Projection.(one Users.active)
      |> distinct
      |> order_by Users.active
      |> select_all db)
  in
  Alcotest.(check (list bool)) "distinct active" [ false; true ] distinct_active;
  let grouped =
    Q.Select.(
      from Users.table Q.Projection.(count ~as_:"count" ())
      |> group_by Users.active
      |> having Q.Expr.(count_ge 2)
      |> select_all db)
  in
  Alcotest.(check (list int)) "group having count" [ 2 ] grouped

let test_sql_select_subquery_cte_window () =
  with_db @@ fun db ->
  seed db;
  let active_ids =
    Q.Select.(
      from Users.table Q.Projection.(one Users.id)
      |> where Q.Expr.(eq Users.active true)
      |> compile)
  in
  let names =
    Q.Select.(
      from Users.table Q.Projection.(one Users.name)
      |> where Q.Expr.(in_select Users.id active_ids)
      |> order_by Users.id
      |> select_all db)
  in
  Alcotest.(check (list string)) "subquery names" [ "Ada"; "Grace" ] names;
  let active_rows =
    Q.Select.(
      from Users.table Q.Projection.(t2 Users.id Users.name)
      |> where Q.Expr.(eq Users.active true)
      |> compile)
  in
  let cte_rows =
    Q.Select.(
      from ActiveUsers.table Q.Projection.(t2 ActiveUsers.id ActiveUsers.name)
      |> with_cte ~name:"active_users" active_rows
      |> order_by ActiveUsers.id
      |> select_all db)
  in
  Alcotest.(check (list (pair int string))) "cte rows"
    [ (1, "Ada"); (2, "Grace") ] cte_rows;
  let row_numbers =
    Q.Select.(
      from Users.table Q.Projection.(row_number ~order_by:Users.id ())
      |> order_by Users.id
      |> select_all db)
  in
  Alcotest.(check (list int)) "row numbers" [ 1; 2; 3 ] row_numbers

let test_sql_invalid_query_errors () =
  with_db @@ fun db ->
  ignore db;
  (match Q.Insert.(into Users.table |> compile) with
   | _ -> Alcotest.fail "empty insert unexpectedly compiled"
   | exception Failure message ->
       Alcotest.(check string) "message"
         "invalid query: INSERT requires at least one value" message)

let test_sql_find_opt_rejects_many_rows () =
  with_db @@ fun db ->
  seed db;
  let query = Q.Select.from Users.table Q.Projection.(one Users.id) in
  match select_find_opt_result db query with
  | Ok _ -> Alcotest.fail "find_opt unexpectedly accepted many rows"
  | Error (Q.Decode_error { operation; message }) ->
      Alcotest.(check string) "operation" "find_opt" operation;
      Alcotest.(check string) "message" "query returned more than one row" message
  | Error err -> Alcotest.failf "unexpected error: %a" Q.pp_error err

let test_sql_value_and_row_helpers () =
  let row =
    [
      ("id", Q.Value.int 42);
      ("name", Q.Value.string "Ada");
      ("active", Q.Value.bool true);
      ("score", Q.Value.float 3.5);
      ("payload", Q.Value.bytes (Bytes.of_string "abc"));
    ]
  in
  Alcotest.(check (option int)) "row int" (Some 42) (Q.Row.int "id" row);
  Alcotest.(check (option string)) "row string" (Some "Ada")
    (Q.Row.string "name" row);
  Alcotest.(check (option bool)) "row bool" (Some true) (Q.Row.bool "active" row);
  Alcotest.(check (option (float 0.0001))) "row float" (Some 3.5)
    (Q.Row.float "score" row);
  Alcotest.(check (list string)) "fields"
    [ "id"; "name"; "active"; "score"; "payload" ]
    (Q.Row.fields row);
  Alcotest.(check bool) "null predicate" true Q.Value.(is_null null);
  Alcotest.(check bool) "value equality" true
    Q.Value.(equal (string "abc") (string "abc"))

let test_sql_schema_and_join_helpers () =
  let db = Q.Connection.create (S.memory_config ()) |> sql_ok in
  Fun.protect
    ~finally:(fun () -> Q.Connection.close db)
    (fun () ->
      Q.Schema.(
        create_table ~if_not_exists:true Users.table
          [
            column ~primary_key:true Users.id;
            column ~not_null:true Users.name;
            column ~not_null:true ~default:"1" Users.active;
            column Users.nickname;
          ]
        |> run_schema db);
      Q.Schema.(
        create_table Posts.table
          [
            column ~primary_key:true Posts.id;
            column ~not_null:true
              ~references:(references ~on_delete:"CASCADE" Users.id)
              Posts.author_id;
            column ~not_null:true Posts.title;
          ]
        |> run_schema db);
      Q.Schema.(
        create_index ~if_not_exists:true ~name:"posts_author_idx" Posts.table
          [ Posts.author_id ]
        |> run_schema db);
      ignore
        Q.Insert.(
          into Users.table
          |> value Users.id 1
          |> value Users.name "Ada"
          |> value Users.active true
          |> value Users.nickname None
          |> compile |> execute_compiled db);
      ignore
        Q.Insert.(
          into Posts.table
          |> value Posts.id 1
          |> value Posts.author_id 1
          |> value Posts.title "Notes"
          |> compile |> execute_compiled db);
      let source =
        Q.Source.inner_join Users.table Posts.table
          ~on:(Q.Join.on_eq Users.id Posts.author_id)
      in
      let rows =
        Q.Select.(
          from_source source
            Q.Projection.(t2 (Q.Join.left Users.name) (Q.Join.right Posts.title))
          |> order_by (Q.Join.right Posts.id)
          |> select_all db)
      in
      Alcotest.(check (list (pair string string))) "joined rows"
        [ ("Ada", "Notes") ] rows)

let test_sql_connection_pool_and_transaction_helpers () =
  let pool =
    Q.Pool.config ~min_connections:1 ~max_connections:1 (S.memory_config ())
    |> Q.Pool.create |> sql_ok
  in
  Fun.protect
    ~finally:(fun () -> Q.shutdown pool)
    (fun () ->
      ignore (Q.exec pool "CREATE TABLE items (id INTEGER PRIMARY KEY)" [] |> sql_ok);
      let rollback =
        Q.with_transaction pool @@ fun conn ->
        ignore
          (Q.Connection.execute conn "INSERT INTO items (id) VALUES (?)"
             [ Q.Value.int 1 ]
          |> sql_ok);
        Error (Q.Invalid_query "force rollback")
      in
      (match rollback with
       | Ok _ -> Alcotest.fail "transaction unexpectedly committed"
       | Error (Q.Invalid_query "force rollback") -> ()
       | Error err -> Alcotest.failf "unexpected error: %a" Q.pp_error err);
      let rows = Q.query pool "SELECT COUNT(*) AS count FROM items" [] |> sql_ok in
      Alcotest.(check (option int)) "rolled back count" (Some 0)
        (match rows with
         | [ row ] -> Q.Row.int "count" row
         | _ -> None);
      ignore (Q.exec pool "INSERT INTO items (id) VALUES (?)" [ Q.Value.int 2 ] |> sql_ok);
      let rows = Q.query pool "SELECT id FROM items ORDER BY id" [] |> sql_ok in
      Alcotest.(check (list int)) "query rows" [ 2 ]
        (List.filter_map (Q.Row.int "id") rows);
      let total, available, in_use =
        List.fold_left
          (fun (total, available, in_use) -> function
            | Q.Pool.Total_connections value -> (value, available, in_use)
            | Q.Pool.Available_connections value -> (total, value, in_use)
            | Q.Pool.In_use_connections value -> (total, available, value)
            | Q.Pool.Waiting_requests _ -> (total, available, in_use))
          (0, 0, 0) (Q.Pool.stats pool)
      in
      Alcotest.(check int) "total connections" 1 total;
      Alcotest.(check int) "available connections" 1 available;
      Alcotest.(check int) "in-use connections" 0 in_use;
      Q.Pool.with_connection pool (fun conn ->
          let tx = Q.Transaction.begin_transaction conn |> sql_ok in
          ignore
            (Q.Connection.execute conn "INSERT INTO items (id) VALUES (?)"
               [ Q.Value.int 3 ]
            |> sql_ok);
          Q.Transaction.rollback tx)
      |> sql_ok;
      let rows = Q.query pool "SELECT COUNT(*) AS count FROM items" [] |> sql_ok in
      Alcotest.(check (option int)) "transaction module rollback" (Some 1)
        (match rows with [ row ] -> Q.Row.int "count" row | _ -> None))

let test_sql_pool_waits_times_out_and_ignores_stale_release () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let pool =
    Q.Pool.config ~max_connections:1 ~acquire_timeout_ms:1_000
      (S.memory_config ())
    |> Q.Pool.create ~clock |> sql_ok
  in
  Fun.protect
    ~finally:(fun () -> Q.shutdown pool)
    (fun () ->
      let first = Q.Pool.acquire pool |> sql_ok in
      let promise, resolver = Eio.Promise.create () in
      Eio.Fiber.both
        (fun () ->
          let result = Q.Pool.acquire pool in
          Eio.Promise.resolve resolver (Result.map Q.Connection.id result);
          match result with
          | Ok conn -> Q.Pool.release pool conn
          | Error _ -> ())
        (fun () ->
          Eio.Time.sleep clock 0.01;
          Alcotest.(check (option int)) "waiting acquire" (Some 1)
            (pool_stat (Q.Pool.stats pool) `Waiting);
          Q.Pool.release pool first);
      Alcotest.(check bool) "waiter acquired after release" true
        (match Eio.Promise.await promise with Ok _ -> true | Error _ -> false);
      let conn = Q.Pool.acquire pool |> sql_ok in
      Q.Pool.release pool conn;
      Q.Pool.release pool conn;
      Alcotest.(check (option int)) "stale release keeps total" (Some 1)
        (pool_stat (Q.Pool.stats pool) `Total);
      Alcotest.(check (option int)) "stale release keeps available" (Some 1)
        (pool_stat (Q.Pool.stats pool) `Available));
  let timeout_pool =
    Q.Pool.config ~max_connections:1 ~acquire_timeout_ms:10 (S.memory_config ())
    |> Q.Pool.create ~clock |> sql_ok
  in
  Fun.protect
    ~finally:(fun () -> Q.shutdown timeout_pool)
    (fun () ->
      let held = Q.Pool.acquire timeout_pool |> sql_ok in
      (match Q.Pool.acquire timeout_pool with
       | Ok conn ->
           Q.Pool.release timeout_pool conn;
           Alcotest.fail "exhausted pool unexpectedly acquired"
       | Error (Q.Pool_error message) ->
           Alcotest.(check bool) "timeout mentions exhausted" true
             (String.length message > 0)
       | Error err -> Alcotest.failf "unexpected error: %a" Q.pp_error err);
      Q.Pool.release timeout_pool held)

let test_sql_connection_rejects_closed_and_invalid_transaction_state () =
  let conn = Q.Connection.create (S.memory_config ()) |> sql_ok in
  Q.Connection.execute_script conn "CREATE TABLE items (id INTEGER PRIMARY KEY)"
  |> sql_ok;
  Q.Connection.begin_transaction conn |> sql_ok;
  (match Q.Connection.begin_transaction conn with
   | Error (Q.Invalid_query message) ->
       Alcotest.(check string) "nested transaction"
         "transaction already in progress" message
   | Ok () -> Alcotest.fail "nested transaction unexpectedly succeeded"
   | Error err -> Alcotest.failf "unexpected error: %a" Q.pp_error err);
  Q.Connection.rollback conn |> sql_ok;
  (match Q.Connection.commit conn with
   | Error (Q.Invalid_query message) ->
       Alcotest.(check string) "commit without transaction"
         "no transaction in progress" message
   | Ok () -> Alcotest.fail "commit without transaction unexpectedly succeeded"
   | Error err -> Alcotest.failf "unexpected error: %a" Q.pp_error err);
  Q.Connection.close conn;
  Alcotest.(check bool) "closed ping" false (Q.Connection.ping conn);
  (match Q.Connection.query conn "SELECT 1" [] with
   | Error (Q.Invalid_query message) ->
       Alcotest.(check string) "closed query" "connection is closed" message
   | Ok _ -> Alcotest.fail "closed query unexpectedly succeeded"
   | Error err -> Alcotest.failf "unexpected error: %a" Q.pp_error err)

let test_sql_eta_pool_adapter_uses_eta_pool () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let blocking_pool =
    Eta.Effect.Blocking.Pool.create ~name:"sql-test"
      {
        max_threads = 2;
        max_queued = 8;
        queue_policy = Eta.Effect.Blocking.Pool.Wait;
        shutdown_policy = Eta.Effect.Blocking.Pool.Drain;
      }
  in
  let timeout = Eta.Duration.ms 250 in
  let program =
    Q.Eta_pool.create ~blocking_pool ~max_size:1 (S.memory_config ())
    |> Eta.Effect.bind (fun pool ->
           Q.Eta_pool.execute_script ~blocking_pool ~timeout pool
             "CREATE TABLE items (id INTEGER PRIMARY KEY);"
           |> Eta.Effect.bind (fun () ->
                  Q.Eta_pool.execute ~blocking_pool ~timeout pool
                    "INSERT INTO items (id) VALUES (?)" [ Q.Value.int 1 ])
           |> Eta.Effect.bind (fun _ ->
                  Q.Eta_pool.query ~blocking_pool ~timeout pool
                    "SELECT COUNT(*) AS count FROM items" [])
           |> Eta.Effect.bind (fun rows ->
                  let stats = Q.Eta_pool.stats pool in
                  Q.Eta_pool.shutdown pool
                  |> Eta.Effect.bind (fun () ->
                         Eta.Effect.Blocking.Pool.shutdown blocking_pool
                         |> Eta.Effect.map (fun () -> (stats.Eta.Pool.opened, rows)))))
  in
  match Eta.Runtime.run rt program with
  | Eta.Exit.Ok (opened, [ row ]) ->
      Alcotest.(check int) "eta pool opened" 1 opened;
      Alcotest.(check (option int)) "eta pool query" (Some 1)
        (Q.Row.int "count" row)
  | Eta.Exit.Ok _ -> Alcotest.fail "unexpected eta pool query shape"
  | Eta.Exit.Error _ -> Alcotest.fail "eta pool adapter failed"

let test_sql_eta_pool_fold_scans_in_batches () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let blocking_pool =
    Eta.Effect.Blocking.Pool.create ~name:"sql-fold-test"
      {
        max_threads = 2;
        max_queued = 8;
        queue_policy = Eta.Effect.Blocking.Pool.Wait;
        shutdown_policy = Eta.Effect.Blocking.Pool.Drain;
      }
  in
  let timeout = Eta.Duration.ms 250 in
  let program =
    Q.Eta_pool.create ~blocking_pool ~max_size:1 (S.memory_config ())
    |> Eta.Effect.bind (fun pool ->
           Q.Eta_pool.execute_script ~blocking_pool ~timeout pool
             "CREATE TABLE items (id INTEGER PRIMARY KEY);\
              INSERT INTO items (id) VALUES (1), (2), (3), (4), (5);"
           |> Eta.Effect.bind (fun () ->
                  Q.Eta_pool.fold ~blocking_pool ~timeout ~batch_size:2 pool
                    "SELECT id FROM items ORDER BY id" [] ~init:(0, 0)
                    ~f:(fun (count, sum) row ->
                      match Q.Row.int "id" row with
                      | Some id -> (count + 1, sum + id)
                      | None -> Alcotest.fail "missing id"))
           |> Eta.Effect.bind (fun result ->
                  Q.Eta_pool.shutdown pool
                  |> Eta.Effect.bind (fun () ->
                         Eta.Effect.Blocking.Pool.shutdown blocking_pool
                         |> Eta.Effect.map (fun () -> result))))
  in
  match Eta.Runtime.run rt program with
  | Eta.Exit.Ok (count, sum) ->
      Alcotest.(check int) "fold count" 5 count;
      Alcotest.(check int) "fold sum" 15 sum
  | Eta.Exit.Error cause ->
      Alcotest.failf "eta pool fold failed: %a"
        (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<sql>"))
        cause

module Eight = struct
  module T = Q.Table.Make (struct
    let name = "eight"
  end)

  include T

  let c1 = column "c1" Q.int
  let c2 = column "c2" Q.int
  let c3 = column "c3" Q.int
  let c4 = column "c4" Q.int
  let c5 = column "c5" Q.int
  let c6 = column "c6" Q.int
  let c7 = column "c7" Q.int
  let c8 = column "c8" Q.int
end

let test_sql_eta_pool_typed_compiled_queries () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let blocking_pool =
    Eta.Effect.Blocking.Pool.create ~name:"sql-typed-test"
      {
        max_threads = 2;
        max_queued = 16;
        queue_policy = Eta.Effect.Blocking.Pool.Wait;
        shutdown_policy = Eta.Effect.Blocking.Pool.Drain;
      }
  in
  let timeout = Eta.Duration.ms 250 in
  let create =
    Q.Schema.(
      create_table Eight.table
        [
          column ~primary_key:true Eight.c1;
          column Eight.c2;
          column Eight.c3;
          column Eight.c4;
          column Eight.c5;
          column Eight.c6;
          column Eight.c7;
          column Eight.c8;
        ]
      |> compile)
  in
  let insert base =
    Q.Insert.(
      into Eight.table
      |> value Eight.c1 base
      |> value Eight.c2 (base + 1)
      |> value Eight.c3 (base + 2)
      |> value Eight.c4 (base + 3)
      |> value Eight.c5 (base + 4)
      |> value Eight.c6 (base + 5)
      |> value Eight.c7 (base + 6)
      |> value Eight.c8 (base + 7)
      |> compile)
  in
  let select_eight =
    Q.Select.(
      from Eight.table
        Q.Projection.(
          t8 Eight.c1 Eight.c2 Eight.c3 Eight.c4 Eight.c5 Eight.c6 Eight.c7
            Eight.c8)
      |> where Q.Expr.(ge Eight.c1 10)
      |> order_by Eight.c1
      |> compile)
  in
  Alcotest.(check string) "compiled select SQL"
    "SELECT \"eight\".\"c1\", \"eight\".\"c2\", \"eight\".\"c3\", \"eight\".\"c4\", \"eight\".\"c5\", \"eight\".\"c6\", \"eight\".\"c7\", \"eight\".\"c8\" FROM \"eight\" WHERE \"eight\".\"c1\" >= ? ORDER BY \"eight\".\"c1\" ASC"
    (Q.Compiled.select_sql select_eight);
  Alcotest.(check int) "compiled param count" 1
    (List.length (Q.Compiled.select_params select_eight));
  let upsert_returning =
    Q.Insert.(
      into Eight.table
      |> value Eight.c1 10
      |> value Eight.c2 100
      |> on_conflict_update [ Eight.c1 ] ~set:[ Eight.c2 ]
      |> returning Q.Projection.(t2 Eight.c1 Eight.c2))
  in
  let update_returning =
    Q.Update.(
      table Eight.table
      |> set Eight.c3 300
      |> where Q.Expr.(eq Eight.c1 10)
      |> returning Q.Projection.(t2 Eight.c1 Eight.c3))
  in
  let delete_returning =
    Q.Delete.(
      from Eight.table
      |> where Q.Expr.(eq Eight.c1 20)
      |> returning Q.Projection.(one Eight.c1))
  in
  let program =
    Q.Eta_pool.create ~blocking_pool ~max_size:1 (S.memory_config ())
    |> Eta.Effect.bind (fun pool ->
           Q.Eta_pool.run_schema ~blocking_pool ~timeout pool create
           |> Eta.Effect.bind (fun () ->
                  Q.Eta_pool.execute_compiled ~blocking_pool ~timeout pool
                    (insert 10))
           |> Eta.Effect.bind (fun _ ->
                  Q.Eta_pool.execute_compiled ~blocking_pool ~timeout pool
                    (insert 20))
           |> Eta.Effect.bind (fun _ ->
                  Q.Eta_pool.returning ~blocking_pool ~timeout pool upsert_returning)
           |> Eta.Effect.bind (fun returned ->
                  Q.Eta_pool.returning ~blocking_pool ~timeout pool update_returning
                  |> Eta.Effect.map (fun updated -> (returned, updated)))
           |> Eta.Effect.bind (fun (returned, updated) ->
                  Q.Eta_pool.with_transaction ~blocking_pool ~timeout pool
                    (fun tx ->
                      Q.Eta_pool.tx_execute_compiled ~blocking_pool ~timeout tx
                        (insert 30)
                      |> Eta.Effect.bind (fun _ ->
                             Q.Eta_pool.tx_select ~blocking_pool ~timeout tx
                               select_eight))
                  |> Eta.Effect.map (fun tx_rows -> (returned, updated, tx_rows)))
           |> Eta.Effect.bind (fun (returned, updated, tx_rows) ->
                  Q.Eta_pool.returning ~blocking_pool ~timeout pool delete_returning
                  |> Eta.Effect.map (fun deleted ->
                         (returned, updated, tx_rows, deleted)))
           |> Eta.Effect.bind (fun (returned, updated, tx_rows, deleted) ->
                  Q.Eta_pool.select ~blocking_pool ~timeout pool select_eight
                  |> Eta.Effect.map (fun rows ->
                         (returned, updated, tx_rows, deleted, rows)))
           |> Eta.Effect.bind (fun (returned, updated, tx_rows, deleted, rows) ->
                  Q.Eta_pool.fold_select ~blocking_pool ~timeout ~batch_size:1 pool
                    select_eight ~init:0
                    ~f:(fun acc (c1, _, _, _, _, _, _, c8) -> acc + c1 + c8)
                  |> Eta.Effect.bind (fun folded ->
                         Q.Eta_pool.shutdown pool
                         |> Eta.Effect.bind (fun () ->
                                Eta.Effect.Blocking.Pool.shutdown blocking_pool
                                |> Eta.Effect.map (fun () ->
                                       ( returned,
                                         updated,
                                         tx_rows,
                                         deleted,
                                         rows,
                                         folded ))))))
  in
  match Eta.Runtime.run rt program with
  | Eta.Exit.Ok
      ( [ (10, 100) ],
        [ (10, 300) ],
        [ _; _; _ ],
        [ 20 ],
        [ (10, 100, 300, _, _, _, _, 17); _ ],
        folded ) ->
      Alcotest.(check int) "typed fold" 94 folded
  | Eta.Exit.Ok _ -> Alcotest.fail "unexpected typed compiled query result"
  | Eta.Exit.Error cause ->
      Alcotest.failf "typed eta pool query failed: %a"
        (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<sql>"))
        cause

let test_sql_eta_pool_timeout_interrupts_and_reuses_connection () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let blocking_pool =
    Eta.Effect.Blocking.Pool.create ~name:"sql-timeout-test"
      {
        max_threads = 2;
        max_queued = 8;
        queue_policy = Eta.Effect.Blocking.Pool.Wait;
        shutdown_policy = Eta.Effect.Blocking.Pool.Drain;
      }
  in
  let long_sql =
    "WITH RECURSIVE cnt(x) AS (\
     SELECT 0 UNION ALL SELECT x + 1 FROM cnt WHERE x < 100000000\
     ) SELECT sum(x) AS total FROM cnt"
  in
  let program =
    Q.Eta_pool.create ~blocking_pool ~max_size:1 (S.memory_config ())
    |> Eta.Effect.bind (fun pool ->
           Q.Eta_pool.query ~blocking_pool ~timeout:(Eta.Duration.ms 5) pool
             long_sql []
           |> Eta.Effect.bind (fun _ ->
                  Eta.Effect.sync (fun () -> Alcotest.fail "expected timeout"))
           |> Eta.Effect.catch
                (function
                  | `Timeout ->
                      Q.Eta_pool.query ~blocking_pool ~timeout:(Eta.Duration.ms 250)
                        pool "SELECT 1 AS one" []
                      |> Eta.Effect.bind (fun rows ->
                             Q.Eta_pool.shutdown pool
                             |> Eta.Effect.bind (fun () ->
                                    Eta.Effect.Blocking.Pool.shutdown blocking_pool
                                    |> Eta.Effect.map (fun () -> rows)))
                  | `Sql _ | `Pool_shutdown | `Pool_shutdown_timeout as err ->
                      Eta.Effect.fail err))
  in
  match Eta.Runtime.run rt program with
  | Eta.Exit.Ok [ row ] ->
      Alcotest.(check (option int)) "connection reusable" (Some 1)
        (Q.Row.int "one" row)
  | Eta.Exit.Ok _ -> Alcotest.fail "unexpected timeout recovery query shape"
  | Eta.Exit.Error cause ->
      Alcotest.failf "eta pool timeout failed: %a"
        (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<sql>"))
        cause

let test_sql_eta_pool_parent_cancel_interrupts_and_reuses_connection () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let blocking_pool =
    Eta.Effect.Blocking.Pool.create ~name:"sql-parent-cancel-test"
      {
        max_threads = 2;
        max_queued = 8;
        queue_policy = Eta.Effect.Blocking.Pool.Wait;
        shutdown_policy = Eta.Effect.Blocking.Pool.Drain;
      }
  in
  let config = S.memory_config () in
  let long_sql =
    "WITH RECURSIVE cnt(x) AS (\
     SELECT 0 UNION ALL SELECT x + 1 FROM cnt WHERE x < 100000000\
     ) SELECT sum(x) AS total FROM cnt"
  in
  let timeout = Eta.Duration.ms 5_000 in
  let supervisor_teardown pool =
    Eta.Supervisor.scoped {
      run =
        fun (type s) sup ->
          let open Eta.Supervisor.Scope in
          let* (_child : (s, Q.Eta_pool.error, Q.Row.t list) Eta.Supervisor.child) =
            start sup
              (lift (Q.Eta_pool.query ~blocking_pool ~timeout pool long_sql []))
          in
          let* () = lift (Eta.Effect.delay (Eta.Duration.ms 5) Eta.Effect.unit) in
          pure ();
    }
  in
  let started = Unix.gettimeofday () in
  let program =
    Q.Eta_pool.create ~blocking_pool ~max_size:1 config
    |> Eta.Effect.bind (fun pool ->
           supervisor_teardown pool
           |> Eta.Effect.bind (fun () ->
                  Q.Eta_pool.query ~blocking_pool ~timeout:(Eta.Duration.ms 250)
                    pool "SELECT 1 AS one" [])
           |> Eta.Effect.bind (fun rows ->
                  Q.Eta_pool.shutdown pool
                  |> Eta.Effect.bind (fun () ->
                         Eta.Effect.Blocking.Pool.shutdown blocking_pool
                         |> Eta.Effect.map (fun () -> rows))))
  in
  match Eta.Runtime.run rt program with
  | Eta.Exit.Ok [ row ] ->
      let elapsed_ms = (Unix.gettimeofday () -. started) *. 1_000.0 in
      Alcotest.(check bool) "parent cancellation interrupted promptly" true
        (elapsed_ms < 200.0);
      Alcotest.(check (option int)) "connection reusable" (Some 1)
        (Q.Row.int "one" row)
  | Eta.Exit.Ok _ -> Alcotest.fail "unexpected parent-cancel recovery query shape"
  | Eta.Exit.Error cause ->
      Alcotest.failf "eta pool parent cancellation failed: %a"
        (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<sql>"))
        cause

let test_sql_migrations_run_run_to_and_undo () =
  let module M = Q.Migrate in
  let v1 = M.Version.from_int 1 |> Result.get_ok in
  let v2 = M.Version.from_int 2 |> Result.get_ok in
  let m1 =
    M.Migration.make ~version:v1 ~description:"create items"
      ~migration_type:M.Simple
      ~sql:"CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)" ()
  in
  let m2_up =
    M.Migration.make ~version:v2 ~description:"seed item"
      ~migration_type:M.Reversible_up
      ~sql:"INSERT INTO items (id, name) VALUES (1, 'Ada')" ()
  in
  let m2_down =
    M.Migration.make ~version:v2 ~description:"seed item"
      ~migration_type:M.Reversible_down
      ~sql:"DELETE FROM items WHERE id = 1" ()
  in
  let source = M.Source.from_migrations [ m2_down; m2_up; m1 ] in
  let pool =
    Q.Pool.config ~min_connections:1 ~max_connections:1 (S.memory_config ())
    |> Q.Pool.create |> sql_ok
  in
  Fun.protect
    ~finally:(fun () -> Q.shutdown pool)
    (fun () ->
      let first = M.run_to pool source ~target:v1 |> migrate_ok in
      Alcotest.(check int) "first applied" 1 (List.length first.applied);
      let second = M.run pool source |> migrate_ok in
      Alcotest.(check int) "second applied" 1 (List.length second.applied);
      Alcotest.(check int) "already applied" 1
        (List.length second.already_applied);
      let rows = Q.query pool "SELECT COUNT(*) AS count FROM items" [] |> sql_ok in
      Alcotest.(check (option int)) "seed count" (Some 1)
        (match rows with [ row ] -> Q.Row.int "count" row | _ -> None);
      let applied = M.list_applied pool |> migrate_ok in
      Alcotest.(check int) "applied versions" 2 (List.length applied);
      let undone = M.undo pool source ~target:v1 |> migrate_ok in
      Alcotest.(check int) "undone migrations" 1 (List.length undone.applied);
      let rows = Q.query pool "SELECT COUNT(*) AS count FROM items" [] |> sql_ok in
      Alcotest.(check (option int)) "undo count" (Some 0)
        (match rows with [ row ] -> Q.Row.int "count" row | _ -> None))

let with_migration_pool f =
  let pool =
    Q.Pool.config ~min_connections:1 ~max_connections:1 (S.memory_config ())
    |> Q.Pool.create |> sql_ok
  in
  Fun.protect ~finally:(fun () -> Q.shutdown pool) (fun () -> f pool)

let test_sql_migrations_reject_dirty_checksum_and_missing () =
  let module M = Q.Migrate in
  let v1 = M.Version.from_int 1 |> Result.get_ok in
  with_migration_pool @@ fun pool ->
  let failing =
    M.Migration.make ~version:v1 ~description:"bad" ~migration_type:M.Simple
      ~sql:"CREATE TABLE broken (" ()
  in
  let failing_source = M.Source.from_migrations [ failing ] in
  (match M.run pool failing_source with
   | Error (M.Migration_execution_error { version; _ }) ->
       Alcotest.(check int64) "failed version" 1L (M.Version.to_int64 version)
   | Ok _ -> Alcotest.fail "bad migration unexpectedly succeeded"
   | Error err -> Alcotest.failf "unexpected migration error: %s" (M.error_to_string err));
  (match M.run pool failing_source with
   | Error (M.Dirty version) ->
       Alcotest.(check int64) "dirty version" 1L (M.Version.to_int64 version)
   | Ok _ -> Alcotest.fail "dirty database unexpectedly accepted"
   | Error err -> Alcotest.failf "unexpected dirty error: %s" (M.error_to_string err));
  with_migration_pool @@ fun pool ->
  let create_a =
    M.Migration.make ~version:v1 ~description:"create a" ~migration_type:M.Simple
      ~sql:"CREATE TABLE a (id INTEGER PRIMARY KEY)" ()
  in
  M.run pool (M.Source.from_migrations [ create_a ]) |> migrate_ok |> ignore;
  let create_b =
    M.Migration.make ~version:v1 ~description:"create a" ~migration_type:M.Simple
      ~sql:"CREATE TABLE b (id INTEGER PRIMARY KEY)" ()
  in
  (match M.run pool (M.Source.from_migrations [ create_b ]) with
   | Error (M.Version_mismatch version) ->
       Alcotest.(check int64) "mismatch version" 1L (M.Version.to_int64 version)
   | Ok _ -> Alcotest.fail "checksum mismatch unexpectedly accepted"
   | Error err -> Alcotest.failf "unexpected checksum error: %s" (M.error_to_string err));
  (match M.run pool (M.Source.from_migrations []) with
   | Error (M.Version_missing version) ->
       Alcotest.(check int64) "missing version" 1L (M.Version.to_int64 version)
   | Ok _ -> Alcotest.fail "missing migration unexpectedly accepted"
   | Error err -> Alcotest.failf "unexpected missing error: %s" (M.error_to_string err))

let write_file path content =
  let output = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr output)
    (fun () -> output_string output content)

let with_temp_dir f =
  let path = Filename.temp_file "eta-sql-migrations-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  let rec remove_tree path =
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Array.iter
          (fun name -> remove_tree (Filename.concat path name))
          (Sys.readdir path);
        Unix.rmdir path
    | _ -> Sys.remove path
  in
  Fun.protect
    ~finally:(fun () -> remove_tree path)
    (fun () -> f path)

let test_sql_migration_source_resolution_metadata () =
  let module M = Q.Migrate in
  let v1 = M.Version.from_int 1 |> Result.get_ok in
  with_temp_dir @@ fun dir ->
  write_file (Filename.concat dir "2_add_orders.up.sql")
    "CREATE TABLE orders (id INTEGER PRIMARY KEY);";
  write_file (Filename.concat dir "1_create_users.sql")
    "-- no-transaction\nCREATE TABLE users (id INTEGER PRIMARY KEY);";
  let migrations =
    M.Source.resolve (M.Source.from_directory dir) |> migrate_ok
  in
  Alcotest.(check int) "resolved migrations" 2 (List.length migrations);
  let first = List.hd migrations in
  Alcotest.(check int64) "first version" 1L
    (M.Version.to_int64 first.M.Migration.version);
  Alcotest.(check bool) "no transaction" true first.M.Migration.no_tx;
  Alcotest.(check string) "description" "create users"
    first.M.Migration.description;
  Alcotest.(check int) "sha256 checksum length" 64
    (String.length first.M.Migration.checksum);
  let equivalent =
    M.Migration.make ~version:v1 ~description:"create users"
      ~migration_type:M.Simple
      ~sql:"CREATE TABLE users (id INTEGER PRIMARY KEY);" ()
  in
  Alcotest.(check string) "directive not in checksum"
    equivalent.M.Migration.checksum first.M.Migration.checksum;
  let ignored = M.Source.{ ignored_checksum_chars = [ ' '; '\n'; '\t'; '\r' ] } in
  write_file (Filename.concat dir "3_spacing.sql")
    "CREATE\n TABLE spaced ( id INTEGER PRIMARY KEY );";
  let migrations =
    M.Source.resolve ~config:ignored (M.Source.from_directory dir) |> migrate_ok
  in
  let spacing = List.find (fun m -> M.Version.to_int64 m.M.Migration.version = 3L) migrations in
  let compact =
    M.Migration.make ~version:(M.Version.from_int 3 |> Result.get_ok)
      ~description:"spacing" ~migration_type:M.Simple
      ~sql:"CREATETABLEspaced(idINTEGERPRIMARYKEY);" ()
  in
  Alcotest.(check string) "ignored chars checksum"
    compact.M.Migration.checksum spacing.M.Migration.checksum;
  (match M.Table_name.from_string "main.__eta_migrations" with
   | Ok table_name ->
       Alcotest.(check string) "dotted table name" "main.__eta_migrations"
         (M.Table_name.to_string table_name)
   | Error err -> Alcotest.failf "%s" (M.Table_name.error_to_string err));
  let skipped_path = Filename.concat dir "4_bad.sql" in
  Unix.mkdir skipped_path 0o700;
  let migrations =
    M.Source.resolve (M.Source.from_directory dir) |> migrate_ok
  in
  Alcotest.(check int) "directory entry skipped" 3 (List.length migrations);
  let bad_path = Filename.concat dir "5_bad.sql" in
  write_file bad_path "CREATE TABLE bad (id INTEGER PRIMARY KEY);";
  Unix.chmod bad_path 0;
  (match M.Source.resolve (M.Source.from_directory dir) with
   | Error
       (M.Source_error
          (M.Read_migration_file_failed { path = failed_path; reason = _ })) ->
       Alcotest.(check string) "failed file path" bad_path failed_path
   | Ok _ -> Alcotest.fail "unreadable migration unexpectedly resolved"
   | Error err -> Alcotest.failf "unexpected source error: %s" (M.error_to_string err))
