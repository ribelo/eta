(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Types
open Dsl_backend

type t = connection

let connect database =
  if_database_open database @@ fun () ->
  wrap "connect" (fun () ->
      let conn =
        {
          database;
          use_mutex = Mutex.create ();
          raw = raw_connect database.raw;
          closed = false;
          active = 0;
        }
      in
      with_database_lock database (fun () ->
          database.connections <- conn :: database.connections);
      conn)

let close (conn : connection) =
  with_database_lock conn.database @@ fun () ->
  if conn.closed || conn.database.closed then Result.Error Closed
  else (
    conn.closed <- true;
    while conn.active > 0 do
      Condition.wait conn.database.condition conn.database.mutex
    done;
    match wrap "disconnect" (fun () -> raw_disconnect conn.raw) with
    | Ok () ->
        conn.database.connections <-
          List.filter (fun live -> live != conn) conn.database.connections;
        Ok ()
    | Result.Error _ as err -> err)

let interrupt (conn : connection) =
  ignore
    (if_connection_open ~serialize:false conn @@ fun () ->
     raw_interrupt conn.raw;
     Ok ())

let query (conn : connection) sql params =
  if_connection_open conn @@ fun () ->
  wrap "query" (fun () -> raw_query conn.raw sql params)

let select conn (compiled : _ Compiled.select) =
  match
    query conn (Compiled.select_sql compiled)
      (Compiled.select_params compiled)
  with
  | Result.Error _ as err -> err
  | Ok rows -> (
      match List.map (Compiled.select_decode compiled) rows with
      | values -> Ok values
      | exception Decode_failure failure ->
          Result.Error
            (Decode_error
               { operation = "select"; message = decode_failure_message failure }))

let returning conn (compiled : _ Compiled.returning) =
  match
    query conn (Compiled.returning_sql compiled)
      (Compiled.returning_params compiled)
  with
  | Result.Error _ as err -> err
  | Ok rows -> (
      match List.map (Compiled.returning_decode compiled) rows with
      | values -> Ok values
      | exception Decode_failure failure ->
          Result.Error
            (Decode_error
               {
                 operation = "returning";
                 message = decode_failure_message failure;
               }))

let execute (conn : connection) sql params =
  if_connection_open conn @@ fun () ->
  wrap "execute" (fun () -> raw_execute conn.raw sql params)

let execute_compiled (conn : connection) (query : Compiled.change) =
  execute conn (Compiled.change_sql query) (Compiled.change_params query)

let exec_script (conn : connection) sql =
  if_connection_open conn @@ fun () ->
  wrap "exec script" (fun () -> raw_exec_script conn.raw sql)

let run_schema conn (schema : Compiled.schema) =
  exec_script conn (Compiled.schema_sql schema)

let begin_transaction ?(mode = Deferred) conn =
  let sql =
    match mode with
    | Deferred -> "BEGIN TRANSACTION"
    | Immediate -> "BEGIN IMMEDIATE TRANSACTION"
  in
  exec_script conn sql

let commit conn = exec_script conn "COMMIT"
let rollback conn = exec_script conn "ROLLBACK"

let transaction ?mode conn f =
  Eta_sql_dsl.transaction ~begin_:(begin_transaction ?mode) ~commit ~rollback
    conn f
