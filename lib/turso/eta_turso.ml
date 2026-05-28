module Value = Eta_sql.Value
module Row = Eta_sql.Row

type raw_db
type raw_stmt

type rc = int

type open_mode =
  | Read_only
  | Read_write
  | Read_write_create

type journal_mode =
  | Mvcc
  | Wal

type config = {
  path : string;
  mode : open_mode;
  busy_timeout_ms : int option;
  foreign_keys : bool;
  journal_mode : journal_mode;
}

type transaction_mode =
  | Read
  | Write
  | Concurrent

type error =
  | Library_unavailable of string
  | Driver_error of {
      operation : string;
      code : rc;
      extended_code : int;
      message : string;
    }
  | Invalid_config of string
  | Decode_error of {
      operation : string;
      message : string;
    }
  | Closed

exception Error of error

type db = {
  raw : raw_db;
  config : config;
  mutable closed : bool;
}

type stmt = {
  db : db;
  raw : raw_stmt;
  mutable finalized : bool;
}

external raw_available : unit -> string option = "eta_turso_available"
external raw_open : string -> (int[@untagged]) -> raw_db = "eta_turso_open_bc" "eta_turso_open"
external raw_close : raw_db -> (int[@untagged]) = "eta_turso_close_bc" "eta_turso_close"
external raw_prepare : raw_db -> string -> raw_stmt = "eta_turso_prepare"
external raw_finalize : raw_stmt -> (int[@untagged]) = "eta_turso_finalize_bc" "eta_turso_finalize"
external raw_step : raw_stmt -> (int[@untagged]) = "eta_turso_step_bc" "eta_turso_step"
external raw_bind_null : raw_stmt -> (int[@untagged]) -> (int[@untagged]) = "eta_turso_bind_null_bc" "eta_turso_bind_null"
external raw_bind_int64 : raw_stmt -> (int[@untagged]) -> (int64[@unboxed]) -> (int[@untagged]) = "eta_turso_bind_int64_bc" "eta_turso_bind_int64"
external raw_bind_double : raw_stmt -> (int[@untagged]) -> (float[@unboxed]) -> (int[@untagged]) = "eta_turso_bind_double_bc" "eta_turso_bind_double"
external raw_bind_text : raw_stmt -> (int[@untagged]) -> string -> (int[@untagged]) = "eta_turso_bind_text_bc" "eta_turso_bind_text"
external raw_bind_blob : raw_stmt -> (int[@untagged]) -> bytes -> (int[@untagged]) = "eta_turso_bind_blob_bc" "eta_turso_bind_blob"
external raw_column_count : raw_stmt -> (int[@untagged]) = "eta_turso_column_count_bc" "eta_turso_column_count"
external raw_column_name : raw_stmt -> (int[@untagged]) -> string = "eta_turso_column_name_bc" "eta_turso_column_name"
external raw_column_type : raw_stmt -> (int[@untagged]) -> (int[@untagged]) = "eta_turso_column_type_bc" "eta_turso_column_type"
external raw_column_int64 : raw_stmt -> (int[@untagged]) -> (int64[@unboxed]) = "eta_turso_column_int64_bc" "eta_turso_column_int64"
external raw_column_double : raw_stmt -> (int[@untagged]) -> (float[@unboxed]) = "eta_turso_column_double_bc" "eta_turso_column_double"
external raw_column_text : raw_stmt -> (int[@untagged]) -> string = "eta_turso_column_text_bc" "eta_turso_column_text"
external raw_column_blob : raw_stmt -> (int[@untagged]) -> bytes = "eta_turso_column_blob_bc" "eta_turso_column_blob"
external raw_changes : raw_db -> (int[@untagged]) = "eta_turso_changes_bc" "eta_turso_changes"
external raw_busy_timeout : raw_db -> (int[@untagged]) -> (int[@untagged]) = "eta_turso_busy_timeout_bc" "eta_turso_busy_timeout"
external raw_errcode : raw_db -> (int[@untagged]) = "eta_turso_errcode_bc" "eta_turso_errcode"
external raw_extended_errcode : raw_db -> (int[@untagged]) = "eta_turso_extended_errcode_bc" "eta_turso_extended_errcode"
external raw_errmsg : raw_db -> string = "eta_turso_errmsg"

let ok = 0
let row = 100
let done_ = 101
let busy = 5
let locked = 6

let sqlite_integer = 1
let sqlite_float = 2
let sqlite_text = 3
let sqlite_blob = 4
let sqlite_null = 5

let pp_error ppf = function
  | Library_unavailable message -> Format.fprintf ppf "turso library unavailable: %s" message
  | Driver_error { operation; code; extended_code; message } ->
      Format.fprintf ppf "%s: rc=%d xrc=%d: %s" operation code extended_code message
  | Invalid_config message -> Format.fprintf ppf "invalid Turso config: %s" message
  | Decode_error { operation; message } -> Format.fprintf ppf "%s: %s" operation message
  | Closed -> Format.pp_print_string ppf "Turso database is closed"

let show_error err = Format.asprintf "%a" pp_error err
let raise_error err = raise (Error err)
let pp_turso_error = pp_error

let available () =
  match raw_available () with
  | None -> Ok ()
  | Some message -> Result.Error (Library_unavailable message)

let open_mode_code = function
  | Read_only -> 0
  | Read_write -> 1
  | Read_write_create -> 2

let journal_mode_sql = function
  | Mvcc -> "mvcc"
  | Wal -> "wal"

let default_config path =
  {
    path;
    mode = Read_write_create;
    busy_timeout_ms = Some 5_000;
    foreign_keys = true;
    journal_mode = Mvcc;
  }

let make_driver_error (db : db) ~operation code =
  Driver_error
    {
      operation;
      code;
      extended_code = raw_extended_errcode db.raw;
      message = raw_errmsg db.raw;
    }

let check db ~operation rc =
  if rc = ok then Ok () else Result.Error (make_driver_error db ~operation rc)

let if_open db f = if db.closed then Result.Error Closed else f ()

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
          let result =
            match f stmt with
            | value -> value
            | exception exn ->
                Result.Error
                  (Decode_error
                     { operation = "execute"; message = Printexc.to_string exn })
          in
          ignore (finalize stmt);
          result)

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
  (match db.config.busy_timeout_ms with
   | None -> Ok ()
   | Some ms -> check db ~operation:"busy timeout" (raw_busy_timeout db.raw ms))
  |> Result.bind (fun () ->
         exec_script db ("PRAGMA foreign_keys = " ^ bool_sql db.config.foreign_keys))
  |> Result.bind (fun () ->
         let expected = journal_mode_sql db.config.journal_mode in
         query_one_string db ("PRAGMA journal_mode = '" ^ expected ^ "'")
         |> Result.bind (fun actual ->
                if String.equal (String.lowercase_ascii actual) expected then Ok ()
                else
                  Result.Error
                    (Invalid_config
                       ("requested journal_mode=" ^ expected ^ " but Turso reported "
                      ^ actual))))

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
          | Result.Error _ as err -> err)
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

module Pool = struct
  type raw_error = [ `Turso of error | `Pool_shutdown | `Pool_shutdown_timeout | `Timeout ]
  type t = (db, raw_error) Eta.Pool.t

  type nonrec error =
    | Turso of error
    | Pool_shutdown
    | Pool_shutdown_timeout
    | Timeout

  let pp_error ppf = function
    | Turso err -> pp_turso_error ppf err
    | Pool_shutdown -> Format.pp_print_string ppf "pool shutdown"
    | Pool_shutdown_timeout -> Format.pp_print_string ppf "pool shutdown timeout"
    | Timeout -> Format.pp_print_string ppf "timeout"

  let to_public_error = function
    | `Turso err -> Turso err
    | `Pool_shutdown -> Pool_shutdown
    | `Pool_shutdown_timeout -> Pool_shutdown_timeout
    | `Timeout -> Timeout

  let public effect = Eta.Effect.map_error to_public_error effect

  let lift_result = function
    | Ok value -> Eta.Effect.pure value
    | Result.Error err -> Eta.Effect.fail (`Turso err)

  let blocking_result ?blocking_pool ?name f =
    Eta.Effect.blocking ?pool:blocking_pool ?name f |> Eta.Effect.bind lift_result

  let acquire ?blocking_pool config =
    blocking_result ?blocking_pool ~name:"turso.open" (fun () -> open_ config)

  let release ?blocking_pool db =
    Eta.Effect.blocking ?pool:blocking_pool ~name:"turso.close" (fun () ->
        ignore (close db))

  let health_check ?blocking_pool db =
    blocking_result ?blocking_pool ~name:"turso.ping" (fun () ->
        match query db "SELECT 1" [] with
        | Ok _ -> Ok ()
        | Result.Error _ as err -> err)

  let create ?blocking_pool ?name ?(max_size = 10) ?max_idle ?idle_lifetime
      ?max_lifetime config =
    Eta.Pool.create ?name ~kind:"turso" ~max_size ?max_idle ?idle_lifetime
      ?max_lifetime ~acquire:(acquire ?blocking_pool config)
      ~release:(release ?blocking_pool)
      ~health_check:(health_check ?blocking_pool) ()
    |> public

  let with_db t f =
    Eta.Pool.with_resource t (fun db -> f db |> Eta.Effect.map_error (function
        | Turso err -> `Turso err
        | Pool_shutdown -> `Pool_shutdown
        | Pool_shutdown_timeout -> `Pool_shutdown_timeout
        | Timeout -> `Timeout))
    |> public

  let query ?blocking_pool t sql params =
    with_db t (fun db ->
        blocking_result ?blocking_pool ~name:"turso.query" (fun () ->
            query db sql params)
        |> public)

  let execute ?blocking_pool t sql params =
    with_db t (fun db ->
        blocking_result ?blocking_pool ~name:"turso.execute" (fun () ->
            execute db sql params)
        |> public)

  let shutdown ?deadline t = Eta.Pool.shutdown ?deadline t |> public
  let stats = Eta.Pool.stats
end
