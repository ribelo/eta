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

val decode_failure_message : decode_failure -> string
val decode_fail : int -> string -> Value.t -> 'a
val row_nth_value : int -> Row.t -> Value.t

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

val ok : rc
val row : rc
val done_ : rc
val busy : rc
val locked : rc

val sqlite_integer : int
val sqlite_float : int
val sqlite_text : int
val sqlite_blob : int
val sqlite_null : int

val pp_error : Format.formatter -> error -> unit
val show_error : error -> string
val raise_error : error -> 'a
val pp_turso_error : Format.formatter -> error -> unit
val available : unit -> (unit, error) result
val open_mode_code : open_mode -> int
val journal_mode_sql : journal_mode -> string
val default_config : string -> config
val make_driver_error : db -> operation:string -> rc -> error
val check : db -> operation:string -> rc -> (unit, error) result
val if_open : db -> (unit -> ('a, error) result) -> ('a, error) result
