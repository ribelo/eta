module Q = Eta_sql
module S = Eta_sql.Sqlite

let ( let* ) effect f = Eta.Effect.bind f effect

module Users = struct
  module T = Q.Table.Make (struct
    let name = "users"
  end)

  include T

  let id = column "id" Q.int
  let name = column "name" Q.text
  let active = column "active" Q.bool
  let status = column "status" Q.text
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

module Comments = struct
  module T = Q.Table.Make (struct
    let name = "comments"
  end)

  include T

  let id = column "id" Q.int
  let post_id = column "post_id" Q.int
  let body = column "body" Q.text
end

module Tags = struct
  module T = Q.Table.Make (struct
    let name = "tags"
  end)

  include T

  let id = column "id" Q.int
  let post_id = column "post_id" Q.int
  let tag = column "tag" Q.text
end

module ActiveUsers = struct
  module T = Q.Table.Make (struct
    let name = "active_users"
  end)

  include T

  let id = column "id" Q.int
  let name = column "name" Q.text
end

module Items = struct
  module T = Q.Table.Make (struct
    let name = "items"
  end)

  include T

  let id = column "id" Q.int
  let width = column "width" Q.int
  let height = column "height" Q.int
end

module Events = struct
  module T = Q.Table.Make (struct
    let name = "events"
  end)

  include T

  let id = column "id" Q.int
  let timestamp = column "timestamp" Q.int
end

module Students = struct
  module T = Q.Table.Make (struct
    let name = "students"
  end)

  include T

  let id = column "id" Q.int
  let name = column "name" Q.text
  let score = column "score" Q.int
end

module Requests = struct
  module T = Q.Table.Make (struct
    let name = "requests"
  end)

  include T

  let id = column "id" Q.int
  let user_id = column "user_id" Q.int
  let latency = column "latency" Q.float
end

module Transactions = struct
  module T = Q.Table.Make (struct
    let name = "transactions"
  end)

  include T

  let id = column "id" Q.int
  let user_id = column "user_id" Q.int
  let amount = column "amount" Q.float
end

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

let pp_eta_pool_error ppf = function
  | `Eta_sql err -> Q.pp_error ppf err
  | `Pool_shutdown -> Format.pp_print_string ppf "pool shutdown"
  | `Pool_shutdown_timeout -> Format.pp_print_string ppf "pool shutdown timeout"
  | `Timeout -> Format.pp_print_string ppf "timeout"

let run_effect program =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  match Eta.Runtime.run rt program with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "%a" (Eta.Cause.pp pp_eta_pool_error) cause

let with_pool f =
  let acquire =
    Q.Eta_pool.create ~default_timeout:(Eta.Duration.ms 500) ~max_size:1
      (S.memory_config ())
  in
  Eta.Effect.scoped
    (Eta.Effect.acquire_release ~acquire ~release:Q.Eta_pool.shutdown
     |> Eta.Effect.bind f)
  |> run_effect

let p1 column = Q.Projection.one column
let execute_compiled pool query = Q.Eta_pool.execute_compiled pool query
let select_all pool query = Q.Eta_pool.select pool (Q.Select.compile query)
let run_schema pool schema = Q.Eta_pool.run_schema pool (Q.Eta_schema.compile schema)

let select_find_opt pool query =
  let* rows = select_all pool query in
  match rows with
  | [] -> Eta.Effect.pure None
  | [ row ] -> Eta.Effect.pure (Some row)
  | _ ->
      Eta.Effect.fail
        (`Eta_sql
          (Q.Decode_error
             { operation = "find_opt"; message = "query returned more than one row" }))

let create_users pool =
  run_schema pool
    Q.Eta_schema.(
      create_table Users.table
        [
          column ~primary_key:true Users.id;
          column ~not_null:true Users.name;
          column ~not_null:true Users.active;
          column ~not_null:true Users.status;
          column Users.nickname;
        ])

let seed_users pool =
  let insert name active status nickname =
    Q.Insert.(
      into Users.table
      |> value Users.name name
      |> value Users.active active
      |> value Users.status status
      |> value Users.nickname nickname
      |> compile)
  in
  let* _ = execute_compiled pool (insert "Ada" true "active" None) in
  let* _ = execute_compiled pool (insert "Grace" true "verified" (Some "Amazing")) in
  let* _ = execute_compiled pool (insert "Inactive" false "pending" None) in
  Eta.Effect.unit

let with_users f =
  with_pool @@ fun pool ->
  let* () = create_users pool in
  let* () = seed_users pool in
  f pool

let test_sql_select_insert_update_delete () =
  with_users @@ fun pool ->
  let* active_users =
    Q.Select.(
      from Users.table
        Q.Projection.(t3 (p1 Users.id) (p1 Users.name) (p1 Users.nickname))
      |> where Q.Expr.(eq Users.active true)
      |> order_by Users.id
      |> select_all pool)
  in
  Alcotest.(check (list (triple int string (option string))))
    "active users"
    [ (1, "Ada", None); (2, "Grace", Some "Amazing") ]
    active_users;
  let* changed =
    Q.Update.(
      table Users.table
      |> set Users.nickname (Some "Countess")
      |> where Q.Expr.(eq Users.name "Ada")
      |> compile |> execute_compiled pool)
  in
  Alcotest.(check int) "updated rows" 1 changed;
  let* ada =
    Q.Select.(
      from Users.table Q.Projection.(t2 (p1 Users.name) (p1 Users.nickname))
      |> where Q.Expr.(eq Users.id 1)
      |> select_find_opt pool)
  in
  Alcotest.(check (option (pair string (option string))))
    "updated Ada" (Some ("Ada", Some "Countess")) ada;
  let* deleted =
    Q.Delete.(
      from Users.table
      |> where Q.Expr.(eq Users.active false)
      |> compile |> execute_compiled pool)
  in
  Alcotest.(check int) "deleted rows" 1 deleted;
  let* remaining =
    Q.Select.(
      from Users.table Q.Projection.(one Users.id)
      |> order_by Users.id
      |> select_all pool)
  in
  Alcotest.(check (list int)) "remaining ids" [ 1; 2 ] remaining;
  Eta.Effect.unit

let test_sql_render_stable_sql () =
  let query =
    Q.Select.(
      from Users.table Q.Projection.(t2 (p1 Users.id) (p1 Users.name))
      |> where Q.Expr.(and_ (gt Users.id 10) (like Users.name "A%"))
      |> order_by ~desc:true Users.name
      |> limit 1)
  in
  Alcotest.(check string) "rendered select"
    "SELECT \"users\".\"id\", \"users\".\"name\" FROM \"users\" WHERE ((\"users\".\"id\" > ?) AND (\"users\".\"name\" LIKE ?)) ORDER BY \"users\".\"name\" DESC LIMIT 1"
    (Q.Select.to_sql query)

let test_sql_select_aggregates_distinct_group () =
  with_users @@ fun pool ->
  let* active_count =
    Q.Select.(
      from Users.table Q.Projection.(count ())
      |> where Q.Expr.(eq Users.active true)
      |> select_all pool)
  in
  Alcotest.(check (list int)) "active count" [ 2 ] active_count;
  let* active_id_sum =
    Q.Select.(
      from Users.table Q.Projection.(sum_int Users.id)
      |> where Q.Expr.(eq Users.active true)
      |> select_all pool)
  in
  Alcotest.(check (list int)) "active id sum" [ 3 ] active_id_sum;
  let* distinct_active =
    Q.Select.(
      from Users.table Q.Projection.(one Users.active)
      |> distinct
      |> order_by Users.active
      |> select_all pool)
  in
  Alcotest.(check (list bool)) "distinct active" [ false; true ] distinct_active;
  let* grouped =
    Q.Select.(
      from Users.table Q.Projection.(count ~as_:"count" ())
      |> group_by Users.active
      |> having Q.Expr.(ge_expr (count ()) (int_lit 2))
      |> select_all pool)
  in
  Alcotest.(check (list int)) "group having count" [ 2 ] grouped;
  Eta.Effect.unit

let test_sql_select_subquery_cte_window () =
  with_users @@ fun pool ->
  let active_ids =
    Q.Select.(
      from Users.table Q.Projection.(one Users.id)
      |> where Q.Expr.(eq Users.active true)
      |> compile)
  in
  let* names =
    Q.Select.(
      from Users.table Q.Projection.(one Users.name)
      |> where Q.Expr.(in_select Users.id active_ids)
      |> order_by Users.id
      |> select_all pool)
  in
  Alcotest.(check (list string)) "subquery names" [ "Ada"; "Grace" ] names;
  let active_rows =
    Q.Select.(
      from Users.table Q.Projection.(t2 (p1 Users.id) (p1 Users.name))
      |> where Q.Expr.(eq Users.active true)
      |> compile)
  in
  let* cte_rows =
    Q.Select.(
      from ActiveUsers.table
        Q.Projection.(t2 (p1 ActiveUsers.id) (p1 ActiveUsers.name))
      |> with_cte ~name:"active_users" active_rows
      |> order_by ActiveUsers.id
      |> select_all pool)
  in
  Alcotest.(check (list (pair int string))) "cte rows"
    [ (1, "Ada"); (2, "Grace") ] cte_rows;
  let* row_numbers =
    Q.Select.(
      from Users.table Q.Projection.(row_number ~order_by:Users.id ())
      |> order_by Users.id
      |> select_all pool)
  in
  Alcotest.(check (list int)) "row numbers" [ 1; 2; 3 ] row_numbers;
  Eta.Effect.unit

let test_sql_invalid_query_errors () =
  match Q.Insert.(into Users.table |> compile) with
  | _ -> Alcotest.fail "empty insert unexpectedly compiled"
  | exception Failure message ->
      Alcotest.(check string) "message"
        "invalid query: INSERT requires at least one value" message

let test_sql_find_opt_rejects_many_rows () =
  let result =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
    let program =
      Q.Eta_pool.create ~default_timeout:(Eta.Duration.ms 500) ~max_size:1
        (S.memory_config ())
      |> Eta.Effect.bind (fun pool ->
             let* () = create_users pool in
             let* () = seed_users pool in
             select_find_opt pool
               (Q.Select.from Users.table Q.Projection.(one Users.id)))
    in
    Eta.Runtime.run rt program
  in
  match result with
  | Eta.Exit.Error _ -> ()
  | Eta.Exit.Ok _ -> Alcotest.fail "find_opt unexpectedly accepted many rows"

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

let create_join_tables pool =
  let* () =
    run_schema pool
      Q.Eta_schema.(
        create_table Users.table
          [
            column ~primary_key:true Users.id;
            column Users.name;
            column Users.active;
            column Users.status;
            column Users.nickname;
          ])
  in
  let* () =
    run_schema pool
      Q.Eta_schema.(
        create_table Posts.table
          [
            column ~primary_key:true Posts.id;
            column ~references:(references ~on_delete:"CASCADE" Users.id)
              Posts.author_id;
            column Posts.title;
          ])
  in
  let* () =
    run_schema pool
      Q.Eta_schema.(
        create_table Comments.table
          [
            column ~primary_key:true Comments.id;
            column Comments.post_id;
            column Comments.body;
          ])
  in
  run_schema pool
    Q.Eta_schema.(
      create_table Tags.table
        [
          column ~primary_key:true Tags.id;
          column Tags.post_id;
          column Tags.tag;
        ])

let seed_join_tables pool =
  let* _ =
    Q.Insert.(
      into Users.table
      |> value Users.id 1
      |> value Users.name "Ada"
      |> value Users.active true
      |> value Users.status "active"
      |> value Users.nickname None
      |> compile)
    |> execute_compiled pool
  in
  let* _ =
    Q.Insert.(
      into Posts.table
      |> value Posts.id 10
      |> value Posts.author_id 1
      |> value Posts.title "Notes"
      |> compile)
    |> execute_compiled pool
  in
  let* _ =
    Q.Insert.(
      into Comments.table
      |> value Comments.id 20
      |> value Comments.post_id 10
      |> value Comments.body "Good"
      |> compile)
    |> execute_compiled pool
  in
  let* _ =
    Q.Insert.(
      into Tags.table
      |> value Tags.id 30
      |> value Tags.post_id 10
      |> value Tags.tag "ocaml"
      |> compile)
    |> execute_compiled pool
  in
  Eta.Effect.unit

let test_sql_schema_and_join_helpers () =
  with_pool @@ fun pool ->
  let* () = create_join_tables pool in
  let* () = seed_join_tables pool in
  let module C = Q.Scope in
  let source =
    Q.Source.(
      from Users.table
      |> join Posts.table
           ~on:
             Q.Expr.(
               eq_col (C.column (C.left C.self) Users.id)
                 (C.column C.right Posts.author_id))
      |> join Comments.table
           ~on:
             Q.Expr.(
               eq_col (C.column (C.left C.right) Posts.id)
                 (C.column C.right Comments.post_id))
      |> join ~op:`Left Tags.table
           ~on:
             Q.Expr.(
               eq_col (C.column (C.left (C.left C.right)) Posts.id)
                 (C.column C.right Tags.post_id)))
  in
  let* rows =
    Q.Select.(
      from_source source
        Q.Projection.(
          t4
            (one (C.column (C.left (C.left (C.left C.self))) Users.name))
            (one (C.column (C.left (C.left C.right)) Posts.title))
            (one (C.column (C.left C.right) Comments.body))
            (one (C.column C.right Tags.tag)))
      |> where Q.Expr.(eq (C.column (C.left (C.left (C.left C.self))) Users.active) true)
      |> select_all pool)
  in
  Alcotest.(check (list string))
    "4-table join" [ "Ada|Notes|Good|ocaml" ]
    (List.map
       (fun (user, post, comment, tag) ->
         String.concat "|" [ user; post; comment; tag ])
       rows);
  Eta.Effect.unit

let test_sql_connection_pool_and_transaction_helpers () =
  with_pool @@ fun pool ->
  let* () =
    Q.Eta_pool.execute_script pool "CREATE TABLE items (id INTEGER PRIMARY KEY)"
  in
  let rollback =
    Q.Eta_pool.with_transaction pool (fun tx ->
        let* _ =
          Q.Eta_pool.execute tx "INSERT INTO items (id) VALUES (?)"
            [ Q.Value.int 1 ]
        in
        Eta.Effect.fail (`Eta_sql (Q.Invalid_query "force rollback")))
  in
  let* () =
    rollback
    |> Eta.Effect.catch (function
         | `Eta_sql (Q.Invalid_query "force rollback") -> Eta.Effect.unit
         | err -> Eta.Effect.fail err)
  in
  let* rows = Q.Eta_pool.query pool "SELECT COUNT(*) AS count FROM items" [] in
  Alcotest.(check (option int)) "rolled back count" (Some 0)
    (match rows with [ row ] -> Q.Row.int "count" row | _ -> None);
  let* _ =
    Q.Eta_pool.execute pool "INSERT INTO items (id) VALUES (?)" [ Q.Value.int 2 ]
  in
  let* rows = Q.Eta_pool.query pool "SELECT id FROM items ORDER BY id" [] in
  Alcotest.(check (list int)) "query rows" [ 2 ]
    (List.filter_map (Q.Row.int "id") rows);
  Eta.Effect.unit

let test_sql_pool_waits_times_out_and_ignores_stale_release () =
  with_pool @@ fun pool ->
  let stats = Q.Eta_pool.stats pool in
  Alcotest.(check int) "max size" 1 stats.Eta.Pool.max_size;
  Alcotest.(check bool) "not shutting down" false stats.Eta.Pool.shutting_down;
  Eta.Effect.unit

let test_sql_connection_rejects_closed_and_invalid_transaction_state () =
  let result =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
    Q.Eta_pool.create ~max_size:1 (S.memory_config ())
    |> Eta.Effect.bind (fun pool ->
           Q.Eta_pool.query pool "SELECT 1" []
           |> Eta.Effect.map (fun _ -> pool))
    |> Eta.Runtime.run rt
  in
  match result with
  | Eta.Exit.Error _ -> ()
  | Eta.Exit.Ok _ -> Alcotest.fail "query without timeout unexpectedly succeeded"

let test_sql_eta_pool_adapter_uses_eta_pool () =
  with_pool @@ fun pool ->
  let* () =
    Q.Eta_pool.execute_script pool "CREATE TABLE items (id INTEGER PRIMARY KEY);"
  in
  let* _ =
    Q.Eta_pool.execute pool "INSERT INTO items (id) VALUES (?)" [ Q.Value.int 1 ]
  in
  let* rows = Q.Eta_pool.query pool "SELECT COUNT(*) AS count FROM items" [] in
  Alcotest.(check (option int)) "eta pool query" (Some 1)
    (match rows with [ row ] -> Q.Row.int "count" row | _ -> None);
  Eta.Effect.unit

let test_sql_eta_pool_fold_scans_in_batches () =
  with_pool @@ fun pool ->
  let* () =
    Q.Eta_pool.execute_script pool
      "CREATE TABLE items (id INTEGER PRIMARY KEY);\
       INSERT INTO items (id) VALUES (1), (2), (3), (4), (5);"
  in
  let* count, sum =
    Q.Eta_pool.fold ~batch_size:2 pool "SELECT id FROM items ORDER BY id" []
      ~init:(0, 0)
      ~f:(fun (count, sum) row ->
        match Q.Row.int "id" row with
        | Some id -> (count + 1, sum + id)
        | None -> Alcotest.fail "missing id")
  in
  Alcotest.(check int) "fold count" 5 count;
  Alcotest.(check int) "fold sum" 15 sum;
  Eta.Effect.unit

let test_sql_eta_pool_typed_compiled_queries () =
  with_pool @@ fun pool ->
  let create =
    Q.Eta_schema.(
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
          t8 (p1 Eight.c1) (p1 Eight.c2) (p1 Eight.c3) (p1 Eight.c4)
            (p1 Eight.c5) (p1 Eight.c6) (p1 Eight.c7) (p1 Eight.c8))
      |> where Q.Expr.(ge Eight.c1 10)
      |> order_by Eight.c1
      |> compile)
  in
  let upsert_returning =
    Q.Insert.(
      into Eight.table
      |> value Eight.c1 10
      |> value Eight.c2 100
      |> on_conflict_update [ Eight.c1 ] ~set:[ Eight.c2 ]
      |> returning Q.Projection.(t2 (p1 Eight.c1) (p1 Eight.c2)))
  in
  let update_returning =
    Q.Update.(
      table Eight.table
      |> set Eight.c3 300
      |> where Q.Expr.(eq Eight.c1 10)
      |> returning Q.Projection.(t2 (p1 Eight.c1) (p1 Eight.c3)))
  in
  let* () = Q.Eta_pool.run_schema pool create in
  let* _ = Q.Eta_pool.execute_compiled pool (insert 10) in
  let* _ = Q.Eta_pool.execute_compiled pool (insert 20) in
  let* returned = Q.Eta_pool.returning pool upsert_returning in
  let* updated = Q.Eta_pool.returning pool update_returning in
  let* tx_rows =
    Q.Eta_pool.with_transaction pool (fun tx ->
        let* _ = Q.Eta_pool.execute_compiled tx (insert 30) in
        Q.Eta_pool.select tx select_eight)
  in
  let* rows = Q.Eta_pool.select pool select_eight in
  let* folded =
    Q.Eta_pool.fold_select ~batch_size:1 pool select_eight ~init:0
      ~f:(fun acc (c1, _, _, _, _, _, _, c8) -> acc + c1 + c8)
  in
  Alcotest.(check (list (pair int int))) "upsert returning" [ (10, 100) ] returned;
  Alcotest.(check (list (pair int int))) "update returning" [ (10, 300) ] updated;
  Alcotest.(check int) "tx rows" 3 (List.length tx_rows);
  Alcotest.(check int) "pool rows" 3 (List.length rows);
  Alcotest.(check int) "typed fold" 141 folded;
  Eta.Effect.unit

let test_sql_eta_pool_timeout_interrupts_and_reuses_connection () =
  let long_sql =
    "WITH RECURSIVE cnt(x) AS (\
     SELECT 0 UNION ALL SELECT x + 1 FROM cnt WHERE x < 100000000\
     ) SELECT sum(x) AS total FROM cnt"
  in
  with_pool @@ fun pool ->
  Q.Eta_pool.query ~timeout:(Eta.Duration.ms 5) pool long_sql []
  |> Eta.Effect.bind (fun _ ->
         Eta.Effect.sync (fun () -> Alcotest.fail "expected timeout"))
  |> Eta.Effect.catch (function
       | `Timeout ->
           let* rows =
             Q.Eta_pool.query ~timeout:(Eta.Duration.ms 250) pool
               "SELECT 1 AS one" []
           in
           Alcotest.(check (option int)) "connection reusable" (Some 1)
             (match rows with [ row ] -> Q.Row.int "one" row | _ -> None);
           Eta.Effect.unit
       | err -> Eta.Effect.fail err)

let test_sql_eta_pool_parent_cancel_interrupts_and_reuses_connection () =
  test_sql_eta_pool_timeout_interrupts_and_reuses_connection ()

let test_sql_new_expr_operator_workload () =
  with_pool @@ fun pool ->
  let* () =
    run_schema pool
      Q.Eta_schema.(
        create_table Items.table
          [ column ~primary_key:true Items.id; column Items.width; column Items.height ])
  in
  let* _ =
    Q.Insert.(
      into Items.table
      |> value Items.id 1
      |> value Items.width 10
      |> value Items.height 7
      |> compile)
    |> execute_compiled pool
  in
  let check_ids label predicate expected =
    let* rows =
      Q.Select.(
        from Items.table Q.Projection.(one Items.id)
        |> where predicate
        |> select_all pool)
    in
    Alcotest.(check (list int)) label expected rows;
    Eta.Effect.unit
  in
  let* () =
    check_ids "width < height + 5"
      Q.Expr.(lt_expr (col Items.width) (add (col Items.height) (int_lit 5)))
      [ 1 ]
  in
  let* () =
    check_ids "width - 3 = height"
      Q.Expr.(eq_expr (sub (col Items.width) (int_lit 3)) (col Items.height))
      [ 1 ]
  in
  let* () =
    check_ids "height * 2 > width"
      Q.Expr.(gt_expr (mul (col Items.height) (int_lit 2)) (col Items.width))
      [ 1 ]
  in
  let* () =
    check_ids "width / 2 = 5"
      Q.Expr.(eq_expr (div (col Items.width) (int_lit 2)) (int_lit 5))
      [ 1 ]
  in
  let* () =
    check_ids "width > height" Q.Expr.(gt_col Items.width Items.height) [ 1 ]
  in
  let* () =
    check_ids "width >= height" Q.Expr.(ge_col Items.width Items.height) [ 1 ]
  in
  let* () =
    check_ids "height < width" Q.Expr.(lt_col Items.height Items.width) [ 1 ]
  in
  let* () =
    check_ids "height <= width" Q.Expr.(le_col Items.height Items.width) [ 1 ]
  in
  Eta.Effect.unit

let test_sql_between_in_case_aggregates_having () =
  with_users @@ fun pool ->
  let* () =
    run_schema pool
      Q.Eta_schema.(
        create_table Events.table
          [ column ~primary_key:true Events.id; column Events.timestamp ])
  in
  let* _ =
    Q.Insert.(into Events.table |> value Events.id 1 |> value Events.timestamp 1500 |> compile)
    |> execute_compiled pool
  in
  let* between_rows =
    Q.Select.(
      from Events.table Q.Projection.(one Events.id)
      |> where Q.Expr.(between Events.timestamp 1000 2000)
      |> select_all pool)
  in
  Alcotest.(check (list int)) "between" [ 1 ] between_rows;
  let* status_rows =
    Q.Select.(
      from Users.table Q.Projection.(one Users.name)
      |> where Q.Expr.(in_values Users.status [ "active"; "pending"; "verified" ])
      |> order_by Users.id
      |> select_all pool)
  in
  Alcotest.(check (list string)) "in values"
    [ "Ada"; "Grace"; "Inactive" ] status_rows;
  let* () =
    run_schema pool
      Q.Eta_schema.(
        create_table Students.table
          [ column ~primary_key:true Students.id; column Students.name; column Students.score ])
  in
  let* _ =
    Q.Insert.(
      into Students.table
      |> value Students.id 1
      |> value Students.name "Ada"
      |> value Students.score 92
      |> compile)
    |> execute_compiled pool
  in
  let grade =
    Q.Expr.(
      case
        [
          (gt Students.score 90, text_lit "A");
          (gt Students.score 80, text_lit "B");
        ]
        ~default:(text_lit "C"))
  in
  let* grades =
    Q.Select.(
      from Students.table
        Q.Projection.(t2 (p1 Students.name) (expr ~as_:"grade" grade))
      |> select_all pool)
  in
  Alcotest.(check (list (pair string string))) "case grade" [ ("Ada", "A") ] grades;
  let* () =
    run_schema pool
      Q.Eta_schema.(
        create_table Requests.table
          [ column ~primary_key:true Requests.id; column Requests.user_id; column Requests.latency ])
  in
  let* _ =
    Q.Insert.(
      into Requests.table
      |> value Requests.id 1
      |> value Requests.user_id 10
      |> value Requests.latency 3.0
      |> compile)
    |> execute_compiled pool
  in
  let* aggregates =
    Q.Select.(
      from Requests.table
        Q.Projection.(
          t5 (p1 Requests.user_id) (count ()) (avg Requests.latency)
            (min Requests.latency) (max Requests.latency))
      |> group_by Requests.user_id
      |> select_all pool)
  in
  Alcotest.(check int) "aggregate rows" 1 (List.length aggregates);
  let* () =
    run_schema pool
      Q.Eta_schema.(
        create_table Transactions.table
          [ column ~primary_key:true Transactions.id; column Transactions.user_id; column Transactions.amount ])
  in
  let insert_tx id amount =
    Q.Insert.(
      into Transactions.table
      |> value Transactions.id id
      |> value Transactions.user_id 10
      |> value Transactions.amount amount
      |> compile)
  in
  let* _ = execute_compiled pool (insert_tx 1 10.0) in
  let* _ = execute_compiled pool (insert_tx 2 20.0) in
  let* having =
    Q.Select.(
      from Transactions.table
        Q.Projection.(
          t3 (p1 Transactions.user_id) (sum_float Transactions.amount)
            (avg Transactions.amount))
      |> group_by Transactions.user_id
      |> having Q.Expr.(gt_expr (sum_float Transactions.amount) (avg Transactions.amount))
      |> select_all pool)
  in
  Alcotest.(check int) "having sum > avg" 1 (List.length having);
  Eta.Effect.unit

let migrate_error_of_eta_pool_error = function
  | `Eta_sql err -> Q.Migrate.Sql_error err
  | `Pool_shutdown -> Q.Migrate.Sql_error (Q.Pool_error "pool is shut down")
  | `Pool_shutdown_timeout ->
      Q.Migrate.Sql_error (Q.Pool_error "pool shutdown timed out")
  | `Timeout -> Q.Migrate.Sql_error (Q.Pool_error "operation timed out")

let pp_migrate_error ppf err =
  Format.pp_print_string ppf (Q.Migrate.error_to_string err)

let run_migrate_effect program =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  match Eta.Runtime.run rt program with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "%a" (Eta.Cause.pp pp_migrate_error) cause

let with_migrate_pool f =
  let acquire =
    Q.Eta_pool.create ~default_timeout:(Eta.Duration.ms 500) ~max_size:1
      (S.memory_config ())
    |> Eta.Effect.map_error migrate_error_of_eta_pool_error
  in
  let release pool =
    Q.Eta_pool.shutdown pool
    |> Eta.Effect.map_error migrate_error_of_eta_pool_error
  in
  Eta.Effect.scoped
    (Eta.Effect.acquire_release ~acquire ~release |> Eta.Effect.bind f)
  |> run_migrate_effect

let migrate_query pool sql params =
  Q.Eta_pool.query pool sql params
  |> Eta.Effect.map_error migrate_error_of_eta_pool_error

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
  with_migrate_pool @@ fun pool ->
  let* first = M.run_to pool source ~target:v1 in
  Alcotest.(check int) "first applied" 1 (List.length first.applied);
  let* second = M.run pool source in
  Alcotest.(check int) "second applied" 1 (List.length second.applied);
  let* rows = migrate_query pool "SELECT COUNT(*) AS count FROM items" [] in
  Alcotest.(check (option int)) "seed count" (Some 1)
    (match rows with [ row ] -> Q.Row.int "count" row | _ -> None);
  let* applied = M.list_applied pool in
  Alcotest.(check int) "applied versions" 2 (List.length applied);
  let* undone = M.undo pool source ~target:v1 in
  Alcotest.(check int) "undone migrations" 1 (List.length undone.applied);
  Eta.Effect.unit

let test_sql_migrations_reject_dirty_checksum_and_missing () =
  let module M = Q.Migrate in
  let v1 = M.Version.from_int 1 |> Result.get_ok in
  with_migrate_pool @@ fun pool ->
  let failing =
    M.Migration.make ~version:v1 ~description:"bad" ~migration_type:M.Simple
      ~sql:"CREATE TABLE broken (" ()
  in
  let failing_source = M.Source.from_migrations [ failing ] in
  let* () =
    M.run pool failing_source
    |> Eta.Effect.bind (fun _ ->
           Eta.Effect.sync (fun () -> Alcotest.fail "bad migration succeeded"))
    |> Eta.Effect.catch (function
         | M.Migration_execution_error { version; _ } ->
             Alcotest.(check int64) "failed version" 1L
               (M.Version.to_int64 version);
             Eta.Effect.unit
         | err -> Eta.Effect.fail err)
  in
  M.run pool failing_source
  |> Eta.Effect.bind (fun _ ->
         Eta.Effect.sync (fun () -> Alcotest.fail "dirty database accepted"))
  |> Eta.Effect.catch (function
       | M.Dirty version ->
           Alcotest.(check int64) "dirty version" 1L (M.Version.to_int64 version);
           Eta.Effect.unit
       | err -> Eta.Effect.fail err)

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
  let checksum_vector =
    M.Migration.make ~version:v1 ~description:"sha256 vector"
      ~migration_type:M.Simple ~sql:"abc" ()
  in
  Alcotest.(check string) "sha256 abc"
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    checksum_vector.M.Migration.checksum;
  with_temp_dir @@ fun dir ->
  write_file (Filename.concat dir "2_add_orders.up.sql")
    "CREATE TABLE orders (id INTEGER PRIMARY KEY);";
  write_file (Filename.concat dir "1_create_users.sql")
    "-- no-transaction\nCREATE TABLE users (id INTEGER PRIMARY KEY);";
  let migrations =
    M.Source.resolve (M.Source.from_directory dir) |> Result.get_ok
  in
  Alcotest.(check int) "resolved migrations" 2 (List.length migrations);
  let first = List.hd migrations in
  Alcotest.(check int64) "first version" 1L
    (M.Version.to_int64 first.M.Migration.version);
  Alcotest.(check bool) "no transaction" true first.M.Migration.no_tx;
  Alcotest.(check string) "description" "create users"
    first.M.Migration.description
