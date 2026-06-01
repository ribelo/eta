(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Types

let bind_value db stmt index = function
  | Value.Null -> check db ~operation:"bind null" (raw_bind_null stmt.raw index)
  | Int value -> check db ~operation:"bind int" (raw_bind_int64 stmt.raw index (Int64.of_int value))
  | Int64 value -> check db ~operation:"bind int64" (raw_bind_int64 stmt.raw index value)
  | Float value -> check db ~operation:"bind float" (raw_bind_double stmt.raw index value)
  | String value -> check db ~operation:"bind text" (raw_bind_text stmt.raw index value)
  | Bool value -> check db ~operation:"bind bool" (raw_bind_int64 stmt.raw index (if value then 1L else 0L))
  | Bytes value -> check db ~operation:"bind blob" (raw_bind_blob stmt.raw index value)

let bind_values db stmt values =
  let rec loop index = function
    | [] -> Ok ()
    | value :: rest -> (
        match bind_value db stmt index value with
        | Ok () -> loop (index + 1) rest
        | Result.Error _ as err -> err)
  in
  loop 1 values

let read_value raw index =
  match raw_column_type raw index with
  | value when value = sqlite_null -> Value.Null
  | value when value = sqlite_integer ->
      let value = raw_column_int64 raw index in
      let min = Int64.of_int min_int in
      let max = Int64.of_int max_int in
      if Int64.compare value min >= 0 && Int64.compare value max <= 0 then
        Int (Int64.to_int value)
      else
        Int64 value
  | value when value = sqlite_float -> Float (raw_column_double raw index)
  | value when value = sqlite_text -> String (raw_column_text raw index)
  | value when value = sqlite_blob -> Bytes (raw_column_blob raw index)
  | _ -> Null

let materialize_row raw =
  let count = raw_column_count raw in
  let rec loop index acc =
    if index < 0 then acc
    else loop (index - 1) ((raw_column_name raw index, read_value raw index) :: acc)
  in
  loop (count - 1) []

let prepare db sql =
  if_open db @@ fun () ->
  match raw_prepare db.raw sql with
  | raw -> Ok { db; raw; finalized = false }
  | exception Failure message ->
      Result.Error
        (Driver_error
           {
             operation = "prepare";
             code = raw_errcode db.raw;
             extended_code = raw_extended_errcode db.raw;
             message;
           })

let finalize stmt =
  if stmt.finalized then Ok ()
  else (
    stmt.finalized <- true;
    check stmt.db ~operation:"finalize" (raw_finalize stmt.raw))

let with_statement db sql params f =
  match prepare db sql with
  | Result.Error _ as err -> err
  | Ok stmt -> (
      match bind_values db stmt params with
      | Result.Error err ->
          ignore (finalize stmt);
          Result.Error err
      | Ok () ->
          Fun.protect ~finally:(fun () -> ignore (finalize stmt)) (fun () ->
              f stmt))

let step stmt = if stmt.finalized then 21 else raw_step stmt.raw

let query db sql params =
  if_open db @@ fun () ->
  with_statement db sql params @@ fun stmt ->
  let rec loop acc =
    let rc = step stmt in
    if rc = row then loop (materialize_row stmt.raw :: acc)
    else if rc = done_ then Ok (List.rev acc)
    else Result.Error (make_driver_error db ~operation:"query" rc)
  in
  loop []

let execute db sql params =
  if_open db @@ fun () ->
  with_statement db sql params @@ fun stmt ->
  let rc = step stmt in
  if rc = done_ then Ok (raw_changes db.raw)
  else Result.Error (make_driver_error db ~operation:"execute" rc)

let exec_script db sql = execute db sql [] |> Result.map (fun _ -> ())

let query_one_string db sql =
  match query db sql [] with
  | Ok [ row ] -> (
      match row with
      | [ (_, String value) ] -> Ok value
      | [ (_, value) ] -> Ok (Value.to_string value)
      | _ -> Result.Error (Decode_error { operation = sql; message = "expected one column" }))
  | Ok _ -> Result.Error (Decode_error { operation = sql; message = "expected one row" })
  | Result.Error _ as err -> err

let bool_sql value = if value then "ON" else "OFF"

let apply_config db =
  Result.bind
    (match db.config.busy_timeout_ms with
     | None -> Ok ()
     | Some ms -> check db ~operation:"busy timeout" (raw_busy_timeout db.raw ms))
    (fun () ->
      Result.bind
        (exec_script db ("PRAGMA foreign_keys = " ^ bool_sql db.config.foreign_keys))
        (fun () ->
          let expected = journal_mode_sql db.config.journal_mode in
          Result.bind
            (query_one_string db ("PRAGMA journal_mode = '" ^ expected ^ "'"))
            (fun actual ->
              if String.equal (String.lowercase_ascii actual) expected then Ok ()
              else
                Result.Error
                  (Invalid_config
                     ("requested journal_mode=" ^ expected ^ " but Turso reported "
                    ^ actual)))))

let open_ config =
  match available () with
  | Result.Error _ as err -> err
  | Ok () -> (
      match raw_open config.path (open_mode_code config.mode) with
      | raw ->
          let db = { raw; config; closed = false } in
          (match apply_config db with
           | Ok () -> Ok db
           | Result.Error err ->
               ignore (raw_close raw);
               Result.Error err)
      | exception Failure message -> Result.Error (Library_unavailable message))

let open_exn config =
  match open_ config with
  | Ok db -> db
  | Result.Error err -> raise_error err

let close db =
  if db.closed then Ok ()
  else (
    db.closed <- true;
    check db ~operation:"close" (raw_close db.raw))

let close_exn db = match close db with Ok () -> () | Result.Error err -> raise_error err

let begin_sql = function
  | Read -> "BEGIN"
  | Write -> "BEGIN IMMEDIATE"
  | Concurrent -> "BEGIN CONCURRENT"

let begin_transaction ?(mode = Write) db =
  if mode = Concurrent && db.config.journal_mode <> Mvcc then
    Result.Error (Invalid_config "BEGIN CONCURRENT requires journal_mode=Mvcc")
  else
    exec_script db (begin_sql mode)

let commit db = exec_script db "COMMIT"
let rollback db = exec_script db "ROLLBACK"

let transaction ?mode db f =
  match begin_transaction ?mode db with
  | Result.Error _ as err -> err
  | Ok () -> (
      match f db with
      | Ok value -> (
          match commit db with
          | Ok () -> Ok value
          | Result.Error _ as err ->
              ignore (rollback db);
              err)
      | Result.Error _ as err ->
          ignore (rollback db);
          err
      | exception exn ->
          ignore (rollback db);
          raise exn)

let is_retryable = function
  | Driver_error { code; _ } -> code = busy || code = locked || code = 1
  | _ -> false

let retry_on_conflict ~max_attempts ~backoff f =
  if max_attempts <= 0 then invalid_arg "Eta_turso.retry_on_conflict: max_attempts must be positive";
  let rec loop attempt =
    match f () with
    | Ok _ as ok -> ok
    | Result.Error err when attempt < max_attempts && is_retryable err ->
        backoff ~attempt;
        loop (attempt + 1)
    | Result.Error _ as err -> err
  in
  loop 1
