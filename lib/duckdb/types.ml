(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type decode_failure = {
  column : int;
  expected : string;
  actual : string;
  value : string;
}

exception Decode_failure of decode_failure

let value_kind = function
  | Value.Null -> "null"
  | Bool _ -> "bool"
  | Int _ -> "int"
  | Int64 _ -> "int64"
  | Float _ -> "float"
  | String _ -> "string"
  | Bytes _ -> "bytes"
  | Decimal _ -> "decimal"
  | Date _ -> "date"
  | Time _ -> "time"
  | Timestamp _ -> "timestamp"
  | Uuid _ -> "uuid"
  | Json _ -> "json"
  | Enum _ -> "enum"
  | List _ -> "list"
  | Struct _ -> "struct"

let decode_failure_message failure =
  Printf.sprintf "column %d: expected %s, got %s (%s)" failure.column
    failure.expected failure.actual failure.value

let decode_fail index expected value =
  raise
    (Decode_failure
       {
         column = index;
         expected;
         actual = value_kind value;
         value = Value.to_string value;
       })

type row_decode_cursor = {
  mutable cached_row : Row.t option;
  mutable next_index : int;
  mutable next_tail : Row.t;
}

let row_decode_cursor =
  (* Domain.Safe.DLS rejects this mutable cursor as contended, but the DLS
     initializer allocates one cursor per domain and row decoding never shares
     that cursor across domains. *)
  (Domain.DLS.new_key [@alert "-unsafe_multidomain"]) (fun () ->
      { cached_row = None; next_index = 0; next_tail = [] })

let missing_column index =
  raise
    (Decode_failure
       {
         column = index;
         expected = "column";
         actual = "missing";
         value = "<missing>";
       })

let rec row_nth_from index current = function
  | [] -> missing_column index
  | (_, value) :: rest ->
      if current = index then (value, rest)
      else row_nth_from index (current + 1) rest

let row_nth_value index row =
  let cursor =
    (Domain.DLS.get [@alert "-unsafe_multidomain"]) row_decode_cursor
  in
  (* Public Row.t stays an association list for named lookups and ABI
     stability, but typed projections decode offsets left-to-right. The
     per-domain cursor advances from the previous tail in that common path,
     avoiding O(N^2) rescans while still falling back cleanly on rewinds. *)
  let current, tail =
    match cursor.cached_row with
    | Some cached_row when cached_row == row && index >= cursor.next_index ->
        (cursor.next_index, cursor.next_tail)
    | Some _ | None -> (0, row)
  in
  let value, next_tail = row_nth_from index current tail in
  cursor.cached_row <- Some row;
  cursor.next_index <- index + 1;
  cursor.next_tail <- next_tail;
  value

type raw_database
type raw_connection
type raw_appender

type database = {
  mutex : Mutex.t;
  condition : Condition.t;
  raw : raw_database;
  mutable closed : bool;
  mutable active : int;
  mutable connections : connection list;
}

and connection = {
  database : database;
  use_mutex : Mutex.t;
  raw : raw_connection;
  mutable closed : bool;
  mutable active : int;
}

type appender = {
  connection : connection;
  use_mutex : Mutex.t;
  raw : raw_appender;
  mutable closed : bool;
  mutable active : int;
}

type config = {
  path : string option;
  threads : int option;
}

type error =
  | Library_unavailable of string
  | Driver_error of {
      operation : string;
      message : string;
    }
  | Decode_error of {
      operation : string;
      message : string;
    }
  | Invalid_value of string
  | Closed

exception Error of error

external raw_available : unit -> string option = "eta_duckdb_available"
external raw_version : unit -> string = "eta_duckdb_version"
external raw_open : string -> raw_database = "eta_duckdb_open"
external raw_close_database : raw_database -> unit = "eta_duckdb_close_database"
external raw_connect : raw_database -> raw_connection = "eta_duckdb_connect"
external raw_disconnect : raw_connection -> unit = "eta_duckdb_disconnect"
external raw_interrupt : raw_connection -> unit = "eta_duckdb_interrupt"
external raw_query : raw_connection -> string -> Value.t list -> Row.t list = "eta_duckdb_query"
external raw_execute : raw_connection -> string -> Value.t list -> int = "eta_duckdb_execute"
external raw_exec_script : raw_connection -> string -> unit = "eta_duckdb_exec_script"
external raw_appender_create : raw_connection -> string option -> string -> raw_appender = "eta_duckdb_appender_create"
external raw_appender_append_row : raw_appender -> Value.t list -> unit = "eta_duckdb_appender_append_row"
external raw_appender_flush : raw_appender -> unit = "eta_duckdb_appender_flush"
external raw_appender_close : raw_appender -> unit = "eta_duckdb_appender_close"

let pp_error ppf = function
  | Library_unavailable message -> Format.fprintf ppf "duckdb library unavailable: %s" message
  | Driver_error { operation; message } -> Format.fprintf ppf "%s: %s" operation message
  | Decode_error { operation; message } -> Format.fprintf ppf "%s: %s" operation message
  | Invalid_value message -> Format.fprintf ppf "invalid DuckDB value: %s" message
  | Closed -> Format.pp_print_string ppf "DuckDB handle is closed"

let show_error err = Format.asprintf "%a" pp_error err
let pp_duckdb_error = pp_error

let available () =
  match raw_available () with
  | None -> Ok ()
  | Some message -> Result.Error (Library_unavailable message)

let wrap operation f =
  match available () with
  | Result.Error _ as err -> err
  | Ok () -> (
      match f () with
      | value -> Ok value
      | exception Failure message -> Result.Error (Driver_error { operation; message }))

let version () = wrap "version" raw_version

let with_database_lock db f =
  Mutex.lock db.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock db.mutex) f

let finish_database_use db =
  with_database_lock db @@ fun () ->
  db.active <- db.active - 1;
  Condition.broadcast db.condition

let begin_database_use db =
  with_database_lock db @@ fun () ->
  if db.closed then Result.Error Closed
  else (
    db.active <- db.active + 1;
    Ok ())

let if_database_open db f =
  match begin_database_use db with
  | Result.Error _ as err -> err
  | Ok () -> Fun.protect ~finally:(fun () -> finish_database_use db) f

let finish_connection_use conn =
  with_database_lock conn.database @@ fun () ->
  conn.active <- conn.active - 1;
  conn.database.active <- conn.database.active - 1;
  Condition.broadcast conn.database.condition

let begin_connection_use conn =
  with_database_lock conn.database @@ fun () ->
  if conn.closed || conn.database.closed then Result.Error Closed
  else (
    conn.active <- conn.active + 1;
    conn.database.active <- conn.database.active + 1;
    Ok ())

let with_mutex mutex f =
  Mutex.lock mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock mutex) f

let if_connection_open ?(serialize = true) conn f =
  match begin_connection_use conn with
  | Result.Error _ as err -> err
  | Ok () ->
      Fun.protect
        ~finally:(fun () -> finish_connection_use conn)
        (fun () ->
          if serialize then with_mutex conn.use_mutex f else f ())

let finish_appender_use appender =
  with_database_lock appender.connection.database @@ fun () ->
  appender.active <- appender.active - 1;
  appender.connection.active <- appender.connection.active - 1;
  appender.connection.database.active <- appender.connection.database.active - 1;
  Condition.broadcast appender.connection.database.condition

let begin_appender_use appender =
  let conn = appender.connection in
  with_database_lock conn.database @@ fun () ->
  if appender.closed || conn.closed || conn.database.closed then Result.Error Closed
  else (
    appender.active <- appender.active + 1;
    conn.active <- conn.active + 1;
    conn.database.active <- conn.database.active + 1;
    Ok ())

let if_appender_open appender f =
  match begin_appender_use appender with
  | Result.Error _ as err -> err
  | Ok () ->
      Fun.protect
        ~finally:(fun () -> finish_appender_use appender)
        (fun () -> with_mutex appender.use_mutex f)

type 'a typ = {
  value : 'a -> Value.t;
  decode : Row.t -> int -> 'a;
  sql_type : string;
}

let int =
  let decode_value index = function
    | Value.Int value -> value
    | Int64 value ->
        let min = Int64.of_int min_int in
        let max = Int64.of_int max_int in
        if Int64.compare value min >= 0 && Int64.compare value max <= 0 then
          Int64.to_int value
        else
          decode_fail index "int within OCaml int range" (Int64 value)
    | value -> decode_fail index "int" value
  in
  {
    value = (fun value -> Value.Int value);
    decode = (fun row index -> decode_value index (row_nth_value index row));
    sql_type = "INTEGER";
  }

let int64 =
  let decode_value index = function
    | Value.Int value -> Int64.of_int value
    | Int64 value -> value
    | value -> decode_fail index "int64" value
  in
  {
    value = (fun value -> Value.Int64 value);
    decode = (fun row index -> decode_value index (row_nth_value index row));
    sql_type = "BIGINT";
  }

let bool =
  let decode_value index = function
    | Value.Bool value -> value
    | Int 0 -> false
    | Int 1 -> true
    | Int64 0L -> false
    | Int64 1L -> true
    | value -> decode_fail index "bool" value
  in
  {
    value = (fun value -> Value.Bool value);
    decode = (fun row index -> decode_value index (row_nth_value index row));
    sql_type = "BOOLEAN";
  }

let float =
  let decode_value index = function
    | Value.Float value -> value
    | value -> decode_fail index "float" value
  in
  {
    value = (fun value -> Value.Float value);
    decode = (fun row index -> decode_value index (row_nth_value index row));
    sql_type = "DOUBLE";
  }

let text =
  let decode_value index = function
    | Value.String value
    | Decimal value
    | Date value
    | Time value
    | Timestamp value
    | Uuid value
    | Json value
    | Enum value ->
        value
    | value -> decode_fail index "text" value
  in
  {
    value = (fun value -> Value.String value);
    decode = (fun row index -> decode_value index (row_nth_value index row));
    sql_type = "VARCHAR";
  }

let blob =
  let decode_value index = function
    | Value.Bytes value -> value
    | value -> decode_fail index "blob" value
  in
  {
    value = (fun value -> Value.Bytes value);
    decode = (fun row index -> decode_value index (row_nth_value index row));
    sql_type = "BLOB";
  }

let decimal =
  let decode_value index = function
    | Value.Decimal value | String value -> value
    | value -> decode_fail index "decimal" value
  in
  {
    value = (fun value -> Value.Decimal value);
    decode = (fun row index -> decode_value index (row_nth_value index row));
    sql_type = "DECIMAL";
  }

let date =
  let decode_value index = function
    | Value.Date value | String value -> value
    | value -> decode_fail index "date" value
  in
  {
    value = (fun value -> Value.Date value);
    decode = (fun row index -> decode_value index (row_nth_value index row));
    sql_type = "DATE";
  }

let time =
  let decode_value index = function
    | Value.Time value | String value -> value
    | value -> decode_fail index "time" value
  in
  {
    value = (fun value -> Value.Time value);
    decode = (fun row index -> decode_value index (row_nth_value index row));
    sql_type = "TIME";
  }

let timestamp =
  let decode_value index = function
    | Value.Timestamp value | String value -> value
    | value -> decode_fail index "timestamp" value
  in
  {
    value = (fun value -> Value.Timestamp value);
    decode = (fun row index -> decode_value index (row_nth_value index row));
    sql_type = "TIMESTAMP";
  }

let uuid =
  let decode_value index = function
    | Value.Uuid value | String value -> value
    | value -> decode_fail index "uuid" value
  in
  {
    value = (fun value -> Value.Uuid value);
    decode = (fun row index -> decode_value index (row_nth_value index row));
    sql_type = "UUID";
  }

let json =
  let decode_value index = function
    | Value.Json value | String value -> value
    | value -> decode_fail index "json" value
  in
  {
    value = (fun value -> Value.Json value);
    decode = (fun row index -> decode_value index (row_nth_value index row));
    sql_type = "JSON";
  }

let enum ?(sql_type = "VARCHAR") () =
  let decode_value index = function
    | Value.Enum value | String value -> value
    | value -> decode_fail index "enum" value
  in
  {
    value = (fun value -> Value.Enum value);
    decode = (fun row index -> decode_value index (row_nth_value index row));
    sql_type;
  }

let list typ =
  {
    value = (fun values -> Value.List (List.map typ.value values));
    decode =
      (fun row index ->
        match row_nth_value index row with
        | Value.List values ->
            List.map (fun value -> typ.decode [("", value)] 0) values
        | value -> decode_fail index "list" value);
    sql_type = typ.sql_type ^ "[]";
  }

let value =
  {
    value = Fun.id;
    decode = (fun row index -> row_nth_value index row);
    sql_type = "ANY";
  }

let nullable typ =
  {
    value = (function None -> Value.Null | Some value -> typ.value value);
    decode =
      (fun row index ->
        match row_nth_value index row with
        | Value.Null -> None
        | _ -> Some (typ.decode row index));
    sql_type = typ.sql_type;
  }
