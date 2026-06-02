(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type decode_failure = {
  column : int;
  expected : string;
  actual : string;
  value : string;
}

exception Decode_failure of decode_failure

val decode_failure_message : decode_failure -> string

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

type transaction_mode =
  | Deferred
  | Immediate

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

val pp_error : Format.formatter -> error -> unit
val show_error : error -> string
val pp_duckdb_error : Format.formatter -> error -> unit
val available : unit -> (unit, error) result
val wrap : string -> (unit -> 'a) -> ('a, error) result
val version : unit -> (string, error) result
val with_database_lock : database -> (unit -> 'a) -> 'a
val if_database_open : database -> (unit -> ('a, error) result) -> ('a, error) result
val if_connection_open :
  ?serialize:bool ->
  connection ->
  (unit -> ('a, error) result) ->
  ('a, error) result
val if_appender_open : appender -> (unit -> ('a, error) result) -> ('a, error) result

type 'a typ = {
  value : 'a -> Value.t;
  decode : Row.t -> int -> 'a;
  sql_type : string;
}

val int : int typ
val int64 : int64 typ
val bool : bool typ
val float : float typ
val text : string typ
val blob : bytes typ
val decimal : string typ
val date : string typ
val time : string typ
val timestamp : string typ
val uuid : string typ
val json : string typ
val enum : ?sql_type:string -> unit -> string typ
val list : 'a typ -> 'a list typ
val value : Value.t typ
val nullable : 'a typ -> 'a option typ
