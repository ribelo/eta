(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type raw_db
type raw_stmt

type rc = int

type open_mode : immutable_data =
  | Read_only
  | Read_write
  | Read_write_create

type journal_mode : immutable_data =
  | Mvcc
  | Wal

type config : immutable_data = {
  path : string;
  mode : open_mode;
  busy_timeout_ms : int option;
  foreign_keys : bool;
  journal_mode : journal_mode;
}

type transaction_mode : immutable_data =
  | Read
  | Write
  | Concurrent

type error : immutable_data =
  | Library_unavailable of string
  | Driver_error of {
      operation : string;
      code : rc;
      extended_code : int;
      message : string;
    }
  | Invalid_config of string
  | Invalid_query of string
  | Decode_error of {
      operation : string;
      message : string;
    }
  | Closed

exception Error of error

type decode_failure : immutable_data = {
  column : int;
  expected : string;
  actual : string;
  value : string;
}

exception Decode_failure of decode_failure

let value_kind = function
  | Value.Null -> "null"
  | Int _ -> "int"
  | Int64 _ -> "int64"
  | Float _ -> "float"
  | String _ -> "string"
  | Bool _ -> "bool"
  | Bytes _ -> "bytes"

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

let row_nth_value index row =
  let rec loop current = function
    | [] ->
        raise
          (Decode_failure
             {
               column = index;
               expected = "column";
               actual = "missing";
               value = "<missing>";
             })
    | (_, value) :: _ when current = index -> value
    | _ :: rest -> loop (current + 1) rest
  in
  loop 0 row

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
external raw_interrupt : raw_db -> unit = "eta_turso_interrupt"
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
  | Invalid_query message -> Format.fprintf ppf "invalid query: %s" message
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
