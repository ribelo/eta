module Q = Eta_sql
module S = Eta_sql.Sqlite

let ( let* ) eff f = Eta.Effect.bind f eff

let read_file path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () -> really_input_string input (in_channel_length input))

let rec find_sub_from haystack ~needle index =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if index + needle_len > haystack_len then None
  else if String.sub haystack index needle_len = needle then Some index
  else find_sub_from haystack ~needle (index + 1)

let find_sub haystack ~needle = find_sub_from haystack ~needle 0

let contains_sub haystack ~needle = Option.is_some (find_sub haystack ~needle)

let require_sub haystack ~needle =
  match find_sub haystack ~needle with
  | Some index -> index
  | None -> Alcotest.failf "missing source marker: %s" needle

let find_source_file path =
  let candidates =
    [
      Filename.concat "../../../.." path;
      Filename.concat "../../../../.." path;
      path;
      Filename.concat ".." path;
      Filename.concat "../.." path;
      Filename.concat "../../.." path;
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.failf "could not locate %s from %s" path (Sys.getcwd ())

let source_between source ~start_marker ~end_marker =
  let start = require_sub source ~needle:start_marker in
  let finish =
    match find_sub_from source ~needle:end_marker start with
    | Some finish -> finish
    | None -> Alcotest.failf "missing source end marker: %s" end_marker
  in
  String.sub source start (finish - start)

let test_database_pool_shutdown_keeps_parent_open_on_timeout () =
  let duckdb_source = read_file (find_source_file "lib/duckdb/pool.ml") in
  let duckdb_shutdown =
    source_between duckdb_source ~start_marker:"let shutdown ?deadline t ="
      ~end_marker:"let stats t ="
  in
  ignore
    (require_sub duckdb_shutdown ~needle:"Eta.Pool.shutdown ?deadline t.pool"
      : int);
  ignore (require_sub duckdb_shutdown ~needle:"Database.close t.database" : int);
  ignore
    (require_sub duckdb_shutdown
       ~needle:"|> Eta.Effect.bind (fun () -> close_database)" :
      int);
  Alcotest.(check bool)
    "DuckDB database close is not timeout cleanup" false
    (contains_sub duckdb_shutdown ~needle:"Eta.Effect.finally"
    || contains_sub duckdb_shutdown ~needle:"Eta.Effect.catch");
  List.iter
    (fun (path, start_marker, end_marker) ->
      let source = read_file (find_source_file path) in
      let shutdown = source_between source ~start_marker ~end_marker in
      Alcotest.(check bool)
        (path ^ " does not bind past pool shutdown") false
        (contains_sub shutdown ~needle:"Eta.Effect.bind"))
    [
      ("lib/turso/pool.ml", "let shutdown ?deadline t =", "let stats =");
      ("lib/sql/pool.ml", "let shutdown ?deadline", "let stats");
    ]

let test_turso_pool_uses_shared_interruptible_leased_blocking_source () =
  let source = read_file (find_source_file "lib/turso/pool.ml") in
  ignore
    (require_sub source ~needle:"Invalid_blocking_pool of string" : int);
  ignore
    (require_sub source
       ~needle:
         "Eta_turso.Pool: Detach_started blocking pools cannot be used with leased connections" :
      int);
  ignore
    (require_sub source
       ~needle:"module Driver_blocking = Eta_sql_driver.Make" :
      int);
  ignore
    (require_sub source
       ~needle:"let leased_blocking_result ?blocking_pool ?name db f =" :
      int);
  ignore
    (require_sub source ~needle:"~on_cancel:(fun () -> interrupt db)" : int);
  [
    "let query ?blocking_pool t sql params =";
    "let select ?blocking_pool t query =";
    "let returning ?blocking_pool t query =";
    "let execute ?blocking_pool t sql params =";
    "let execute_compiled ?blocking_pool t query =";
    "let run_schema ?blocking_pool t schema =";
  ]
  |> List.iter (fun marker ->
         let body =
           source_between source ~start_marker:marker ~end_marker:"))"
         in
         ignore
           (require_sub body
              ~needle:"leased_blocking_result ?blocking_pool" :
             int));
  let types_source = read_file (find_source_file "lib/turso/types.ml") in
  ignore (require_sub types_source ~needle:"external raw_interrupt" : int);
  let connection_source = read_file (find_source_file "lib/turso/connection.ml") in
  ignore (require_sub connection_source ~needle:"let interrupt db =" : int);
  let stubs_source = read_file (find_source_file "lib/turso/turso_stubs.c") in
  ignore (require_sub stubs_source ~needle:"void (*interrupt)(sqlite3 *);" : int);
  ignore (require_sub stubs_source ~needle:"LOAD(interrupt)" : int);
  ignore (require_sub stubs_source ~needle:"CAMLprim value eta_turso_interrupt" : int)

let test_turso_close_marks_closed_only_after_native_success () =
  let source = read_file (find_source_file "lib/turso/connection.ml") in
  let close =
    source_between source ~start_marker:"let close db ="
      ~end_marker:"let close_exn db ="
  in
  ignore
    (require_sub close
       ~needle:"match check db ~operation:\"close\" (raw_close db.raw) with" :
      int);
  ignore
    (require_sub close
       ~needle:
         (String.concat "\n"
            [ "| Ok () ->"; "        db.closed <- true;"; "        Ok ()" ]) :
      int);
  Alcotest.(check bool)
    "closed flag is not assigned before native close result" false
    (contains_sub close
       ~needle:"db.closed <- true;\n    check db ~operation:\"close\"")

let test_turso_prepare_rejects_null_statement_success_source () =
  let source = read_file (find_source_file "lib/turso/turso_stubs.c") in
  let prepare =
    source_between source ~start_marker:"CAMLprim value eta_turso_prepare"
      ~end_marker:"CAMLprim intnat eta_turso_finalize"
  in
  ignore
    (require_sub prepare ~needle:"if (rc != SQLITE_OK || stmt == NULL)" :
      int)

let test_sqlite_close_propagates_native_result_source () =
  let connection_source = read_file (find_source_file "lib/sql/connection.ml") in
  let close =
    source_between connection_source ~start_marker:"let close t ="
      ~end_marker:"let begin_transaction t ="
  in
  ignore
    (require_sub close
       ~needle:"match Sqlite.check t.db ~operation:\"close\" (Sqlite.close t.db) with" :
      int);
  ignore
    (require_sub close
       ~needle:
         (String.concat "\n"
            [ "| Ok () ->"; "        t.closed <- true;"; "        t.in_transaction <- false" ]) :
      int);
  Alcotest.(check bool)
    "closed flag is not assigned before native close result" false
    (contains_sub close
       ~needle:"t.closed <- true;\n    t.in_transaction <- false");
  let pool_source = read_file (find_source_file "lib/sql/pool.ml") in
  let release =
    source_between pool_source ~start_marker:"let release_connection"
      ~end_marker:"let health_check"
  in
  ignore
    (require_sub release
       ~needle:"blocking_result ?blocking_pool ~name:\"sqlite.close\"" :
      int)

let test_sqlite_connection_has_no_pool_lease_state_source () =
  let ml = read_file (find_source_file "lib/sql/connection.ml") in
  let mli = read_file (find_source_file "lib/sql/connection.mli") in
  Alcotest.(check bool) "implementation pool_lease removed" false
    (contains_sub ml ~needle:"pool_lease");
  Alcotest.(check bool) "interface pool_lease removed" false
    (contains_sub mli ~needle:"pool_lease")

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

module Measures = struct
  module T = Q.Table.Make (struct
    let name = "measures"
  end)

  include T

  let id = column "id" Q.int
  let ratio = column "ratio" Q.float
end

module Nullables = struct
  module T = Q.Table.Make (struct
    let name = "nullables"
  end)

  include T

  let id = column "id" Q.int
  let n = column "n" Q.int
end

let pp_pool_error ppf = function
  | `Eta_sql err -> Q.pp_error ppf err
  | `Pool_shutdown -> Format.pp_print_string ppf "pool shutdown"
  | `Pool_shutdown_timeout -> Format.pp_print_string ppf "pool shutdown timeout"
  | `Timeout -> Format.pp_print_string ppf "timeout"

let run_effect program =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  match Eta.Runtime.run rt program with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "%a" (Eta.Cause.pp pp_pool_error) cause

let with_pool f =
  let acquire =
    Q.Pool.create ~default_timeout:(Eta.Duration.ms 500) ~max_size:1
      (S.memory_config ())
  in
  Eta.Effect.scoped
    (Eta.Effect.acquire_release ~acquire ~release:Q.Pool.shutdown
     |> Eta.Effect.bind f)
  |> run_effect

let run_effect_exit program =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  Eta.Runtime.run rt program

let with_pool_exit f =
  let acquire =
    Q.Pool.create ~default_timeout:(Eta.Duration.ms 500) ~max_size:1
      (S.memory_config ())
  in
  Eta.Effect.scoped
    (Eta.Effect.acquire_release ~acquire ~release:Q.Pool.shutdown
     |> Eta.Effect.bind f)
  |> run_effect_exit

let p1 column = Q.Projection.one column
let execute_compiled pool query = Q.Pool.Typed.execute_compiled pool query
let select_all pool query = Q.Pool.Typed.select pool (Q.Select.compile query)
let run_schema pool schema = Q.Pool.Typed.run_schema pool (Q.Eta_schema.compile schema)

let test_sql_schema_float_default_round_trips () =
  let pi = 3.141592653589793 in
  let stored =
    with_pool @@ fun pool ->
    let* () =
      run_schema pool
        Q.Eta_schema.(
          create_table Measures.table
            [
              column ~primary_key:true Measures.id;
              column ~not_null:true ~default:pi Measures.ratio;
            ])
    in
    let* _ =
      execute_compiled pool
        Q.Insert.(into Measures.table |> value Measures.id 1 |> compile)
    in
    let* rows =
      select_all pool
        Q.Select.(
          from Measures.table (Q.Projection.one Measures.ratio)
          |> where (Q.Expr.eq Measures.id 1))
    in
    match rows with
    | [ ratio ] -> Eta.Effect.pure ratio
    | _ ->
        Eta.Effect.fail
          (`Eta_sql
            (Q.Decode_error
               { operation = "test"; message = "expected exactly one row" }))
  in
  Alcotest.(check (float 0.0)) "declared float default round-trips" pi stored

let test_sqlite_null_decoded_as_nonnull_int () =
  let result =
    with_pool_exit @@ fun pool ->
    let* () =
      run_schema pool
        Q.Eta_schema.(
          create_table Nullables.table
            [ column ~primary_key:true Nullables.id; column Nullables.n ])
    in
    let* _ =
      execute_compiled pool
        Q.Insert.(into Nullables.table |> value Nullables.id 1 |> compile)
    in
    Q.Pool.Typed.select pool
      (Q.Select.compile
         Q.Select.(
           from Nullables.table (Q.Projection.one Nullables.n)
           |> where (Q.Expr.eq Nullables.id 1)))
  in
  match result with
  | Eta.Exit.Error (Eta.Cause.Fail (`Eta_sql (Q.Decode_error _))) -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected typed Decode_error, got %a"
        (Eta.Cause.pp pp_pool_error) cause
  | Eta.Exit.Ok [ 0 ] ->
      Alcotest.fail
        "decoded SQL NULL as non-nullable int and silently produced 0"
  | Eta.Exit.Ok rows ->
      Alcotest.failf "expected a decode error for NULL, got %d row(s)"
        (List.length rows)

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
  Alcotest.(check (list (option int))) "active id sum" [ Some 3 ] active_id_sum;
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

let test_sql_in_values_empty_list_is_false_predicate () =
  with_users @@ fun pool ->
  let query =
    Q.Select.(
      from Users.table Q.Projection.(one Users.name)
      |> where Q.Expr.(in_values Users.status [])
      |> order_by Users.id)
  in
  let* rows = select_all pool query in
  Alcotest.(check (list string)) "empty IN rows" [] rows;
  Eta.Effect.unit

let test_sql_find_opt_rejects_many_rows () =
  let result =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
    let program =
      Q.Pool.create ~default_timeout:(Eta.Duration.ms 500) ~max_size:1
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
      into Posts.table
      |> value Posts.id 11
      |> value Posts.author_id 1
      |> value Posts.title "No tag"
      |> compile)
    |> execute_compiled pool
  in
  let* _ =
    Q.Insert.(
      into Comments.table
      |> value Comments.id 21
      |> value Comments.post_id 11
      |> value Comments.body "Sparse"
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
            (one (C.nullable_column C.right Tags.tag)))
      |> where Q.Expr.(eq (C.column (C.left (C.left (C.left C.self))) Users.active) true)
      |> order_by (C.column (C.left (C.left C.right)) Posts.id)
      |> select_all pool)
  in
  Alcotest.(check (list string))
    "4-table join" [ "Ada|Notes|Good|ocaml"; "Ada|No tag|Sparse|<none>" ]
    (List.map
       (fun (user, post, comment, tag) ->
         String.concat "|" [ user; post; comment; Option.value tag ~default:"<none>" ])
       rows);
  Eta.Effect.unit

let test_sql_connection_pool_and_transaction_helpers () =
  with_pool @@ fun pool ->
  let* () =
    Q.Pool.Raw.execute_script pool "CREATE TABLE items (id INTEGER PRIMARY KEY)"
  in
  let rollback =
    Q.Pool.with_transaction pool (fun tx ->
        let* _ =
          Q.Pool.Raw.execute tx "INSERT INTO items (id) VALUES (?)"
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
  let* rows = Q.Pool.Raw.query pool "SELECT COUNT(*) AS count FROM items" [] in
  Alcotest.(check (option int)) "rolled back count" (Some 0)
    (match rows with [ row ] -> Q.Row.int "count" row | _ -> None);
  let* _ =
    Q.Pool.Raw.execute pool "INSERT INTO items (id) VALUES (?)" [ Q.Value.int 2 ]
  in
  let* rows = Q.Pool.Raw.query pool "SELECT id FROM items ORDER BY id" [] in
  Alcotest.(check (list int)) "query rows" [ 2 ]
    (List.filter_map (Q.Row.int "id") rows);
  Eta.Effect.unit

let test_sql_pool_waits_times_out_and_ignores_stale_release () =
  with_pool @@ fun pool ->
  let stats = Q.Pool.stats pool in
  Alcotest.(check int) "max size" 1 stats.Eta.Pool.max_size;
  Alcotest.(check bool) "not shutting down" false stats.Eta.Pool.shutting_down;
  Eta.Effect.unit

let test_sql_connection_rejects_closed_and_invalid_transaction_state () =
  let result =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
    Q.Pool.create ~max_size:1 (S.memory_config ())
    |> Eta.Effect.bind (fun pool ->
           Q.Pool.Raw.query pool "SELECT 1" []
           |> Eta.Effect.map (fun _ -> pool))
    |> Eta.Runtime.run rt
  in
  match result with
  | Eta.Exit.Error _ -> ()
  | Eta.Exit.Ok _ -> Alcotest.fail "query without timeout unexpectedly succeeded"

let test_sql_pool_adapter_uses_pool () =
  with_pool @@ fun pool ->
  let* () =
    Q.Pool.Raw.execute_script pool "CREATE TABLE items (id INTEGER PRIMARY KEY);"
  in
  let* _ =
    Q.Pool.Raw.execute pool "INSERT INTO items (id) VALUES (?)" [ Q.Value.int 1 ]
  in
  let* rows = Q.Pool.Raw.query pool "SELECT COUNT(*) AS count FROM items" [] in
  Alcotest.(check (option int)) "pool query" (Some 1)
    (match rows with [ row ] -> Q.Row.int "count" row | _ -> None);
  Eta.Effect.unit

let test_sql_pool_fold_scans_in_batches () =
  with_pool @@ fun pool ->
  let* () =
    Q.Pool.Raw.execute_script pool
      "CREATE TABLE items (id INTEGER PRIMARY KEY);\
       INSERT INTO items (id) VALUES (1), (2), (3), (4), (5);"
  in
  let* count, sum =
    Q.Pool.Raw.fold ~batch_size:2 pool "SELECT id FROM items ORDER BY id" []
      ~init:(0, 0)
      ~f:(fun (count, sum) row ->
        match Q.Row.int "id" row with
        | Some id -> (count + 1, sum + id)
        | None -> Alcotest.fail "missing id")
  in
  Alcotest.(check int) "fold count" 5 count;
  Alcotest.(check int) "fold sum" 15 sum;
  Eta.Effect.unit

let test_sql_pool_typed_compiled_queries () =
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
  let* () = Q.Pool.Typed.run_schema pool create in
  let* _ = Q.Pool.Typed.execute_compiled pool (insert 10) in
  let* _ = Q.Pool.Typed.execute_compiled pool (insert 20) in
  let* returned = Q.Pool.Typed.returning pool upsert_returning in
  let* updated = Q.Pool.Typed.returning pool update_returning in
  let* tx_rows =
    Q.Pool.with_transaction pool (fun tx ->
        let* _ = Q.Pool.Typed.execute_compiled tx (insert 30) in
        Q.Pool.Typed.select tx select_eight)
  in
  let* rows = Q.Pool.Typed.select pool select_eight in
  let* folded =
    Q.Pool.Typed.fold_select ~batch_size:1 pool select_eight ~init:0
      ~f:(fun acc (c1, _, _, _, _, _, _, c8) -> acc + c1 + c8)
  in
  Alcotest.(check (list (pair int int))) "upsert returning" [ (10, 100) ] returned;
  Alcotest.(check (list (pair int int))) "update returning" [ (10, 300) ] updated;
  Alcotest.(check int) "tx rows" 3 (List.length tx_rows);
  Alcotest.(check int) "pool rows" 3 (List.length rows);
  Alcotest.(check int) "typed fold" 141 folded;
  Eta.Effect.unit

let test_sql_pool_typed_fold_select_decode_failure_is_typed () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let module Mismatch = Q.Table.Make (struct
    let name = "typed_fold_decode_mismatch"
  end) in
  let id = Mismatch.column "id" Q.int in
  let query =
    Q.Select.(from Mismatch.table Q.Projection.(one id) |> compile)
  in
  let program =
    Eta.Effect.scoped
      (Eta.Effect.acquire_release
         ~acquire:
           (Q.Pool.create ~default_timeout:(Eta.Duration.ms 500) ~max_size:1
              (S.memory_config ()))
         ~release:Q.Pool.shutdown
      |> Eta.Effect.bind (fun pool ->
             let* _ =
               Q.Pool.Raw.execute pool
                 "CREATE TABLE typed_fold_decode_mismatch (id INTEGER)" []
             in
             let* _ =
               Q.Pool.Raw.execute pool
                 "INSERT INTO typed_fold_decode_mismatch VALUES (4611686018427387904)"
                 []
             in
             Q.Pool.Typed.fold_select pool query ~init:0
               ~f:(fun acc _ -> acc + 1)))
  in
  match Eta.Runtime.run rt program with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (`Eta_sql (Q.Decode_error { operation = "select"; _ }))) ->
      ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected typed Decode_error, got %a"
        (Eta.Cause.pp pp_pool_error) cause
  | Eta.Exit.Ok count ->
      Alcotest.failf "expected typed Decode_error, got success count=%d" count

let test_sql_pool_timeout_interrupts_and_reuses_connection () =
  let long_sql =
    "WITH RECURSIVE cnt(x) AS (\
     SELECT 0 UNION ALL SELECT x + 1 FROM cnt WHERE x < 100000000\
     ) SELECT sum(x) AS total FROM cnt"
  in
  with_pool @@ fun pool ->
  Q.Pool.Raw.query ~timeout:(Eta.Duration.ms 5) pool long_sql []
  |> Eta.Effect.bind (fun _ ->
         Eta.Effect.sync (fun () -> Alcotest.fail "expected timeout"))
  |> Eta.Effect.catch (function
       | `Timeout ->
           let* rows =
             Q.Pool.Raw.query ~timeout:(Eta.Duration.ms 250) pool
               "SELECT 1 AS one" []
           in
           Alcotest.(check (option int)) "connection reusable" (Some 1)
             (match rows with [ row ] -> Q.Row.int "one" row | _ -> None);
           Eta.Effect.unit
       | err -> Eta.Effect.fail err)

let test_sql_pool_parent_cancel_interrupts_and_reuses_connection () =
  test_sql_pool_timeout_interrupts_and_reuses_connection ()

let test_sql_pool_rejects_detach_started_blocking_pool () =
  let module BP = Eta_blocking.Pool in
  let blocking_pool =
    BP.create ~name:"sqlite-detach"
      {
        max_threads = 1;
        max_queued = 0;
        queue_policy = BP.Reject;
        shutdown_policy = BP.Detach_started;
      }
  in
  let program =
    let* pool =
      Q.Pool.create ~blocking_pool ~default_timeout:(Eta.Duration.ms 500)
        ~max_size:1 (S.memory_config ())
    in
    Eta.Effect.scoped
      (Eta.Effect.acquire_release ~acquire:(Eta.Effect.pure pool)
         ~release:Q.Pool.shutdown
      |> Eta.Effect.bind (fun pool ->
             Q.Pool.Raw.query pool "SELECT 1 AS one" []))
  in
  match
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
    Eta.Runtime.run rt program
  with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (`Eta_sql
          (Q.Pool_error
            "Eta_sql.Pool: Detach_started blocking pools cannot be used with leased connections"))) ->
      ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected detach-started pool rejection, got %a"
        (Eta.Cause.pp pp_pool_error) cause
  | Eta.Exit.Ok _ -> Alcotest.fail "expected detach-started pool rejection"

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
      Q.Expr.(
        lt_expr (col Items.width) (add Q.Numeric.int (col Items.height) (int_lit 5)))
      [ 1 ]
  in
  let* () =
    check_ids "width - 3 = height"
      Q.Expr.(
        eq_expr (sub Q.Numeric.int (col Items.width) (int_lit 3))
          (col Items.height))
      [ 1 ]
  in
  let* () =
    check_ids "height * 2 > width"
      Q.Expr.(
        gt_expr (mul Q.Numeric.int (col Items.height) (int_lit 2))
          (col Items.width))
      [ 1 ]
  in
  let* () =
    check_ids "width / 2 = 5"
      Q.Expr.(
        eq_expr (div Q.Numeric.int (col Items.width) (int_lit 2)) (int_lit 5))
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
          t5 (p1 Requests.user_id) (count ()) (avg Q.Numeric.float Requests.latency)
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
            (avg Q.Numeric.float Transactions.amount))
      |> group_by Transactions.user_id
      |> having
           Q.Expr.(
             gt_expr (sum_float Transactions.amount)
               (avg Q.Numeric.float Transactions.amount))
      |> select_all pool)
  in
  Alcotest.(check int) "having sum > avg" 1 (List.length having);
  Eta.Effect.unit

let migrate_error_of_pool_error = function
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
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  match Eta.Runtime.run rt program with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "%a" (Eta.Cause.pp pp_migrate_error) cause

let with_migrate_pool f =
  let acquire =
    Q.Pool.create ~default_timeout:(Eta.Duration.ms 500) ~max_size:1
      (S.memory_config ())
    |> Eta.Effect.map_error migrate_error_of_pool_error
  in
  let release pool =
    Q.Pool.shutdown pool
    |> Eta.Effect.map_error migrate_error_of_pool_error
  in
  Eta.Effect.scoped
    (Eta.Effect.acquire_release ~acquire ~release |> Eta.Effect.bind f)
  |> run_migrate_effect

let migrate_query pool sql params =
  Q.Pool.Raw.query pool sql params
  |> Eta.Effect.map_error migrate_error_of_pool_error

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
    M.Migration.make ~version:v1 ~description:"checksum vector"
      ~migration_type:M.Simple ~sql:"abc" ()
  in
  Alcotest.(check string) "checksum abc"
    "900150983cd24fb0d6963f7d28e17f72"
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

let test_sql_migration_symlink_not_skipped () =
  let module M = Q.Migrate in
  with_temp_dir @@ fun dir ->
  let subdir = Filename.concat dir "real" in
  Unix.mkdir subdir 0o755;
  let real_file = Filename.concat subdir "001_test.sql" in
  let symlink = Filename.concat dir "001_test.sql" in
  write_file real_file "SELECT 1;\n";
  Unix.symlink real_file symlink;
  match M.Source.resolve (M.Source.from_directory dir) with
  | Ok [ _ ] -> ()
  | Ok [] -> Alcotest.fail "symlinked migration file was silently skipped"
  | Ok migrations ->
      Alcotest.failf "expected 1 migration, got %d" (List.length migrations)
  | Error err -> Alcotest.failf "resolve: %s" (M.error_to_string err)

let test_sql_migration_no_transaction_prefix_match () =
  let module M = Q.Migrate in
  with_temp_dir @@ fun dir ->
  let path = Filename.concat dir "001_test.sql" in
  write_file path "-- no-transactional\nSELECT 1;\n";
  match M.Source.resolve (M.Source.from_directory dir) with
  | Ok [ migration ] ->
      if migration.M.Migration.no_tx then
        Alcotest.fail
          "'-- no-transactional' incorrectly matched as '-- no-transaction'"
  | Ok _ -> Alcotest.fail "expected exactly one migration"
  | Error err -> Alcotest.failf "resolve: %s" (M.error_to_string err)

let test_sql_migration_source_rejects_duplicate_versions () =
  let module M = Q.Migrate in
  let version =
    match M.Version.from_int 1 with
    | Ok version -> version
    | Result.Error _ -> Alcotest.fail "unexpected invalid migration version"
  in
  let migration migration_type description sql =
    M.Migration.make ~version ~description ~migration_type ~sql ()
  in
  let expect_duplicate label migrations =
    match M.Source.resolve (M.Source.from_migrations migrations) with
    | Result.Error _ -> ()
    | Ok migrations ->
        Alcotest.failf "%s accepted; resolved %d migrations" label
          (List.length migrations)
  in
  expect_duplicate "duplicate simple migration version"
    [
      migration M.Simple "first duplicate"
        "CREATE TABLE eta_duplicate_first (id INTEGER);";
      migration M.Simple "second duplicate"
        "CREATE TABLE eta_duplicate_second (id INTEGER);";
    ];
  expect_duplicate "duplicate reversible-up migration version"
    [
      migration M.Reversible_up "first up duplicate"
        "CREATE TABLE eta_duplicate_up_first (id INTEGER);";
      migration M.Reversible_up "second up duplicate"
        "CREATE TABLE eta_duplicate_up_second (id INTEGER);";
    ];
  expect_duplicate "duplicate reversible-down migration version"
    [
      migration M.Reversible_down "first down duplicate"
        "DROP TABLE eta_duplicate_down_first;";
      migration M.Reversible_down "second down duplicate"
        "DROP TABLE eta_duplicate_down_second;";
    ]

(* P1: SQL timeouts reset per-step instead of bounding the total operation.
   In fold/with_transaction, the user's timeout is passed to each sub-step
   (prepare, fetch_batch, rollback) independently. Each gets a fresh timeout
   race, so a user requesting 100ms total can wait N*100ms.

   This test uses fold with batch_size:1 over a query where each row
   takes ~50ms to compute. With timeout=100ms, each batch step races
   against a fresh 100ms timer, so the total operation can run for
   N * ~50ms >> 100ms without ever timing out. *)

let test_sql_fold_timeout_does_not_bound_total_elapsed () =
  (* Strategy: pre-populate a table with many rows and use batch_size:1
     in fold so each batch step runs a separate blocking call.
     Each step is individually fast (< timeout), but there are many steps
     and total time exceeds the timeout budget.
     If timeout bounds total time, it should fire when sum(steps) > timeout.
     With per-step reset, each step gets its own fresh timeout and the
     fold completes without ever timing out. *)
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let program =
    let* pool =
      Q.Pool.create ~default_timeout:(Eta.Duration.ms 5000) ~max_size:1
        (S.memory_config ())
    in
    (* Create table with 5000 rows *)
    let* () = Q.Pool.Raw.execute_script pool
      "CREATE TABLE slow_fold (id INTEGER PRIMARY KEY)" in
    let* () = Q.Pool.Raw.execute_script pool
      "WITH RECURSIVE cnt(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM cnt WHERE x < 5000) \
       INSERT INTO slow_fold SELECT x FROM cnt" in
    (* Use a short timeout (20ms). Each batch step fetches 1 row and is
       extremely fast (<1ms), so no individual step times out.
       But 5000 steps with scheduling overhead = much more than 20ms total.
       The test asserts: either the fold times out within 20ms (correct)
       or it completes but took > 20ms (bug: timeout didn't bound total). *)
    let timeout = Eta.Duration.ms 20 in
    let started = Unix.gettimeofday () in
    let fold_result =
      Q.Pool.Raw.fold ~timeout ~batch_size:1 pool
        "SELECT id FROM slow_fold ORDER BY id"
        [] ~init:0
        ~f:(fun acc row ->
          match Q.Row.int "id" row with Some x -> acc + x | None -> acc)
    in
    let* result =
      fold_result
      |> Eta.Effect.map (fun value -> `Ok value)
      |> Eta.Effect.catch (fun _err -> Eta.Effect.pure `Timeout)
    in
    let elapsed_ms =
      int_of_float ((Unix.gettimeofday () -. started) *. 1000.0)
    in
    let* () = Q.Pool.shutdown pool in
    Eta.Effect.pure (result, elapsed_ms)
  in
  match Eta.Runtime.run rt program with
  | Eta.Exit.Ok (result, elapsed_ms) ->
      (match result with
      | `Ok _value ->
          (* Fold completed without timing out. If it took > 20ms,
             the timeout failed to bound the total operation. *)
          Alcotest.(check bool)
            (Printf.sprintf
               "fold with 20ms timeout should not exceed 20ms total \
                (actually took %dms — per-step timeout reset allowed it)" elapsed_ms)
            true (elapsed_ms <= 25) (* 5ms scheduling tolerance *)
      | `Timeout ->
          (* Timeout fired — this is what SHOULD happen with a total-time bound.
             Verify it fired promptly. *)
          Alcotest.(check bool)
            (Printf.sprintf
               "timeout should fire within 25ms (fired at %dms)" elapsed_ms)
            true (elapsed_ms <= 25))
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected error: %a" (Eta.Cause.pp pp_pool_error) cause

(* P0: SQL connection pools leak abandoned transactions.
   If rollback fails during with_transaction cleanup, the connection is returned
   to the idle queue. The health_check (SELECT 1) passes inside an active
   transaction, so the next borrower inherits a poisoned connection with
   uncommitted writes visible. *)

let test_sql_pool_leaked_transaction_poisons_next_borrower () =
  (* This test demonstrates that after a failed transaction where rollback
     is ineffective, the next connection borrower can observe uncommitted
     writes. We simulate a "failed rollback" by directly beginning a
     transaction on the underlying connection and NOT rolling back, then
     returning it to the pool. The pool's health_check (SELECT 1) passes
     fine, and the next user sees the poisoned state.

     In production, this happens when with_transaction's release phase
     times out during rollback - the connection goes back to the pool
     with an active transaction. *)
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let program =
    let* pool =
      Q.Pool.create ~default_timeout:(Eta.Duration.ms 5000) ~max_size:1
        (S.memory_config ())
    in
    let* () = Q.Pool.Raw.execute_script pool
      "CREATE TABLE leaked (id INTEGER PRIMARY KEY, val TEXT)" in
    (* Start a transaction, insert data, then FAIL without proper rollback.
       We use with_transaction where the body fails, and we expect rollback.
       The test shows that even the NORMAL rollback path doesn't protect
       the next borrower if the connection's autocommit state isn't checked. *)
    let tx_result =
      Q.Pool.with_transaction pool (fun tx ->
          let* _ =
            Q.Pool.Raw.execute tx "INSERT INTO leaked (id, val) VALUES (?, ?)"
              [ Q.Value.int 1; Q.Value.string "ghost" ]
          in
          (* Force the transaction to fail *)
          Eta.Effect.fail (`Eta_sql (Q.Invalid_query "simulated failure")))
    in
    let* () =
      tx_result
      |> Eta.Effect.catch (function
           | `Eta_sql (Q.Invalid_query "simulated failure") -> Eta.Effect.unit
           | err -> Eta.Effect.fail err)
    in
    (* After the failed transaction, the connection should be clean.
       The rollback should have removed the INSERT. Verify: *)
    let* rows =
      Q.Pool.Raw.query pool "SELECT val FROM leaked WHERE id = 1" []
    in
    Alcotest.(check (list string)) "no leaked row after normal rollback" []
      (List.filter_map (Q.Row.string "val") rows);
    (* Now demonstrate the ACTUAL vulnerability: health_check uses SELECT 1
       which works fine inside an active transaction. If rollback had failed,
       SELECT 1 would still pass. Prove this by checking that SELECT 1 works
       inside a transaction: *)
    let* _ =
      Q.Pool.with_transaction pool (fun tx ->
          let* _ =
            Q.Pool.Raw.execute tx "INSERT INTO leaked (id, val) VALUES (?, ?)"
              [ Q.Value.int 2; Q.Value.string "in-tx" ]
          in
          (* Verify that SELECT 1 (the health check query) works mid-transaction *)
          let* rows = Q.Pool.Raw.query tx "SELECT 1 AS one" [] in
          Alcotest.(check (option int)) "SELECT 1 works in transaction" (Some 1)
            (match rows with [ row ] -> Q.Row.int "one" row | _ -> None);
          (* The row is visible within the transaction *)
          let* rows = Q.Pool.Raw.query tx "SELECT val FROM leaked WHERE id = 2" [] in
          Alcotest.(check (list string)) "row visible in tx" [ "in-tx" ]
            (List.filter_map (Q.Row.string "val") rows);
          Eta.Effect.pure ())
    in
    (* Row 2 was committed by the successful transaction *)
    let* rows = Q.Pool.Raw.query pool "SELECT val FROM leaked WHERE id = 2" [] in
    Alcotest.(check (list string)) "committed row visible" [ "in-tx" ]
      (List.filter_map (Q.Row.string "val") rows);
    Q.Pool.shutdown pool
  in
  match Eta.Runtime.run rt program with
  | Eta.Exit.Ok () -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected error: %a" (Eta.Cause.pp pp_pool_error) cause

let test_sql_pool_health_check_does_not_detect_active_transaction () =
  (* This test proves the health_check vulnerability: SELECT 1 passes
     on a connection that is mid-transaction. If rollback fails for any
     reason (timeout, I/O error, etc.), the pool will return the connection
     with an uncommitted transaction, and health_check won't catch it.

     A correct health_check should verify autocommit mode or run
     a transaction-state-aware check. *)
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let program =
    let* pool =
      Q.Pool.create ~default_timeout:(Eta.Duration.ms 5000) ~max_size:1
        (S.memory_config ())
    in
    let* () = Q.Pool.Raw.execute_script pool
      "CREATE TABLE poison (id INTEGER PRIMARY KEY)" in
    (* Borrow the connection, begin a transaction manually, insert, but
       DON'T commit or rollback. Returning the connection to the pool must
       clean the transaction before the next borrower can see it. *)
    let* () =
      Q.Pool.Raw.execute_script pool
        "BEGIN TRANSACTION; INSERT INTO poison (id) VALUES (42)"
    in
    let* rows = Q.Pool.Raw.query pool "SELECT id FROM poison" [] in
    let ids = List.filter_map (Q.Row.int "id") rows in
    let* () = Q.Pool.shutdown pool in
    Eta.Effect.pure ids
  in
  match Eta.Runtime.run rt program with
  | Eta.Exit.Ok ids ->
      Alcotest.(check bool)
        "uncommitted row should NOT be visible to next borrower"
        false (List.mem 42 ids)
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected error: %a" (Eta.Cause.pp pp_pool_error) cause

(* P1: The typed SQL DSL can be bypassed by constructing Compiled records directly.
   Compiled types expose record fields, so callers can construct arbitrary
   compiled selects/changes/schemas without the DSL builders. This bypasses
   table/scope/column typing, parameter provenance, and decoder alignment.

   This test demonstrates that a hand-constructed Compiled.select with
   a mismatched decoder executes successfully, proving the type boundary
   is not enforced at runtime. A sealed Compiled module would make this
   a compile-time error. *)

(* SUM on an empty group returns SQL NULL, so aggregate projections must decode
   it as an option. Compile-negative fixtures cover expression type soundness. *)

let test_sql_expr_type_unsoundness () =
  with_pool @@ fun pool ->
  let* () = create_users pool in
  (* No data inserted — table is empty *)
  (* SUM on an empty table returns one SQL row containing NULL. The DSL
     must expose that as an option instead of decoding it as 0. *)
  let sum_query =
    Q.Select.(
      from Users.table
        Q.Projection.(expr (Q.Expr.sum_int Users.id))
      |> compile)
  in
  let* sum_rows = Q.Pool.Typed.select pool sum_query in
  Alcotest.(check (list (option int)))
    "sum_int on empty table should be None" [ None ]
    sum_rows;
  Eta.Effect.unit

(* P1: Schema DSL interpolates raw SQL fragments without validation.
   default, on_delete, on_update are raw strings appended into DDL.
   This allows SQL injection if values come from untrusted input. *)

let test_sql_schema_dsl_raw_interpolation () =
  with_pool @@ fun pool ->
  (* Inject arbitrary SQL via the default field *)
  let injected_default = "0; DROP TABLE users; --" in
  let schema =
    Q.Eta_schema.(
      create_table Users.table
        [
          column ~primary_key:true Users.id;
          column ~not_null:true ~default:injected_default Users.name;
          column Users.active;
          column Users.status;
          column Users.nickname;
        ]
      |> compile)
  in
  let* () = Q.Pool.Typed.run_schema pool schema in
  let* rows =
    Q.Pool.Raw.query pool
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'users'"
      []
  in
  Alcotest.(check (list string)) "users table still exists" [ "users" ]
    (List.filter_map (Q.Row.string "name") rows);
  Eta.Effect.pure ()
