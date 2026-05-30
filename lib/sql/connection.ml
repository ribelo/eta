module Compiled = Dsl.Compiled

type t = {
  db : Sqlite.db;
  id : string;
  created_at : float;
  mutable last_used : float;
  mutable closed : bool;
  mutable in_transaction : bool;
  mutable pool_lease : int;
}

let next_id = Atomic.make 0

let fresh_id () =
  let value = Atomic.fetch_and_add next_id 1 + 1 in
  "eta-sql-" ^ string_of_int value

let now = Unix.gettimeofday

let create config =
  match Sqlite.open_with_config config with
  | db ->
      let created_at = now () in
      Ok
        {
          db;
          id = fresh_id ();
          created_at;
          last_used = created_at;
          closed = false;
          in_transaction = false;
          pool_lease = 0;
        }
  | exception Sqlite.Error err -> Result.Error (Types.Sqlite err)
  | exception exn ->
      Result.Error
        (Types.Invalid_query ("open connection failed: " ^ Printexc.to_string exn))

let sqlite t = t.db
let touch t = t.last_used <- now ()
let closed_error = Types.Invalid_query "connection is closed"
let already_in_transaction = Types.Invalid_query "transaction already in progress"
let no_transaction = Types.Invalid_query "no transaction in progress"

let sync_transaction_state t =
  if not t.closed then t.in_transaction <- not (Sqlite.autocommit t.db)

let if_open t f =
  if t.closed then
    Result.Error closed_error
  else
    f ()

let query t sql params =
  if_open t @@ fun () ->
  touch t;
  Types.with_dynamic_statement t.db sql params @@ fun stmt ->
  let rec loop acc =
    let rc = Sqlite.step stmt in
    if Sqlite.rc_equal rc Sqlite.row then
      loop (Types.materialize_row stmt :: acc)
    else if Sqlite.rc_equal rc Sqlite.done_ then
      Ok (List.rev acc)
    else
      match Types.check_sqlite t.db ~operation:"query" rc with
      | Ok () -> Types.unexpected_sqlite_step ~operation:"query" rc
      | Result.Error err -> Result.Error err
  in
  loop []

let select t (query : _ Compiled.select) =
  if_open t @@ fun () ->
  touch t;
  Types.with_dynamic_statement t.db (Compiled.select_sql query)
    (Compiled.select_params query) @@ fun stmt ->
  let rec loop acc =
    let rc = Sqlite.step stmt in
    if Sqlite.rc_equal rc Sqlite.row then
      loop (Compiled.select_decode query stmt :: acc)
    else if Sqlite.rc_equal rc Sqlite.done_ then
      Ok (List.rev acc)
    else
      match Types.check_sqlite t.db ~operation:"select" rc with
      | Ok () -> Types.unexpected_sqlite_step ~operation:"select" rc
      | Result.Error err -> Result.Error err
  in
  loop []

let returning t (query : _ Compiled.returning) =
  if_open t @@ fun () ->
  touch t;
  Types.with_dynamic_statement t.db (Compiled.returning_sql query)
    (Compiled.returning_params query) @@ fun stmt ->
  let rec loop acc =
    let rc = Sqlite.step stmt in
    if Sqlite.rc_equal rc Sqlite.row then
      loop (Compiled.returning_decode query stmt :: acc)
    else if Sqlite.rc_equal rc Sqlite.done_ then
      Ok (List.rev acc)
    else
      match Types.check_sqlite t.db ~operation:"returning" rc with
      | Ok () -> Types.unexpected_sqlite_step ~operation:"returning" rc
      | Result.Error err -> Result.Error err
  in
  loop []

let execute t sql params =
  if_open t @@ fun () ->
  touch t;
  Types.with_dynamic_statement t.db sql params @@ fun stmt ->
  let rc = Sqlite.step stmt in
  if Sqlite.rc_equal rc Sqlite.done_ then (
    sync_transaction_state t;
    Ok (Sqlite.changes t.db)
  ) else
    match Types.check_sqlite t.db ~operation:"execute" rc with
    | Ok () -> Types.unexpected_sqlite_step ~operation:"execute" rc
    | Result.Error err -> Result.Error err

let execute_compiled t (query : Compiled.change) =
  if_open t @@ fun () ->
  touch t;
  Types.with_dynamic_statement t.db (Compiled.change_sql query)
    (Compiled.change_params query) @@ fun stmt ->
  let rc = Sqlite.step stmt in
  if Sqlite.rc_equal rc Sqlite.done_ then (
    sync_transaction_state t;
    Ok (Sqlite.changes t.db)
  ) else
    match Types.check_sqlite t.db ~operation:"execute" rc with
    | Ok () -> Types.unexpected_sqlite_step ~operation:"execute" rc
    | Result.Error err -> Result.Error err

let execute_script t sql =
  if_open t @@ fun () ->
  touch t;
  match Sqlite.exec_script_result t.db sql with
  | Ok () ->
      sync_transaction_state t;
      Ok ()
  | Result.Error err -> Result.Error (Types.Sqlite err)

let run_schema t (schema : Compiled.schema) =
  execute_script t (Compiled.schema_sql schema)

let prepare_migration t sql = if_open t @@ fun () -> Ok [ sql ]

let ensure_autocommit t =
  if_open t @@ fun () ->
  if Sqlite.autocommit t.db then (
    t.in_transaction <- false;
    Ok ()
  ) else
    match Sqlite.rollback_result t.db with
    | Ok () ->
        sync_transaction_state t;
        if t.in_transaction then
          Result.Error (Types.Pool_error "connection rollback left transaction open")
        else
          Ok ()
    | Result.Error err ->
        sync_transaction_state t;
        Result.Error (Types.Sqlite err)

let ping t =
  (not t.closed)
  &&
  match ensure_autocommit t with
  | Result.Error _ -> false
  | Ok () -> (
      match query t "SELECT 1" [] with
      | Ok [ row ] -> Row.int "1" row = Some 1
      | _ -> false)

let close t =
  if not t.closed then (
    t.closed <- true;
    t.in_transaction <- false;
    ignore (Sqlite.close t.db))

let begin_transaction t =
  if_open t @@ fun () ->
  if t.in_transaction then
    Result.Error already_in_transaction
  else
    match Sqlite.begin_transaction_result t.db with
    | Ok () ->
        t.in_transaction <- true;
        Ok ()
    | Result.Error err -> Result.Error (Types.Sqlite err)

let commit t =
  if_open t @@ fun () ->
  if not t.in_transaction then
    Result.Error no_transaction
  else
    match Sqlite.commit_result t.db with
    | Ok () ->
        t.in_transaction <- false;
        Ok ()
    | Result.Error err -> Result.Error (Types.Sqlite err)

let rollback t =
  if_open t @@ fun () ->
  if not t.in_transaction then
    Result.Error no_transaction
  else
    match Sqlite.rollback_result t.db with
    | Ok () ->
        t.in_transaction <- false;
        Ok ()
    | Result.Error err -> Result.Error (Types.Sqlite err)

let with_transaction t f =
  match begin_transaction t with
  | Result.Error _ as err -> err
  | Ok () -> (
      match f t with
      | Ok value -> (
          match commit t with
          | Ok () -> Ok value
          | Result.Error _ as err -> err)
      | Result.Error _ as err ->
          ignore (rollback t);
          err
      | exception exn ->
          ignore (rollback t);
          raise exn)

let id t = t.id
let created_at t = t.created_at
let last_used t = t.last_used
let pool_lease t = t.pool_lease
let set_pool_lease t lease = t.pool_lease <- lease
