(** Low-allocation SQLite connector.

    This module is deliberately connector-level: explicit database handles,
    prepared statements, bind operations, stepping, and typed column reads.
    Higher-level query construction belongs to a separate experiment. *)

type db
(** SQLite database handle. *)

type stmt
(** Prepared statement. A statement keeps its database handle reachable. *)

type rc : immutable_data = private int
(** SQLite result code. *)

type open_mode : immutable_data =
  | Read_only
  | Read_write
  | Read_write_create

type journal_mode : immutable_data =
  [ `Delete
  | `Truncate
  | `Persist
  | `Memory
  | `Wal
  | `Off
  ]

type synchronous : immutable_data =
  [ `Extra
  | `Full
  | `Normal
  | `Off
  ]

type config : immutable_data = {
  path : string;
  mode : open_mode;
  busy_timeout_ms : int option;
  foreign_keys : bool;
  journal_mode : journal_mode option;
  synchronous : synchronous option;
  cache_size : int option;
}

type transaction_mode : immutable_data =
  | Deferred
  | Immediate
  | Exclusive

type error : immutable_data = {
  operation : string;
  code : rc;
  message : string;
}

exception Error of error

val pp_error : Format.formatter -> error -> unit

val ok : rc
val row : rc
val done_ : rc
val misuse : rc
val range : rc
val constraint_ : rc
val busy : rc
val locked : rc
val interrupt_ : rc

val sqlite_integer : int
val sqlite_float : int
val sqlite_text : int
val sqlite_blob : int
val sqlite_null : int

val rc_code : rc -> int
val rc_name : rc -> string
val rc_equal : rc -> rc -> bool

val open_ : ?mode:open_mode -> string -> db
(** Open a SQLite database path. The default mode is [Read_write_create].
    [":memory:"] opens an in-memory database. *)

val open_memory : unit -> db
val default_config : string -> config
val memory_config : unit -> config
val open_with_config : config -> db
val with_db : config -> (db -> 'a) -> 'a

val close : db -> rc
(** Close a database handle. Statements may still be finalized after closing. *)

val prepare_result : db -> string -> (stmt, error) result
val prepare : db -> string -> stmt
(** Prepare SQL or raise {!Error}. *)

val finalize : stmt -> rc
val reset : stmt -> rc
val clear_bindings : stmt -> rc
val bind_parameter_count : stmt -> int

val bind_null : stmt -> int -> rc
val bind_int64 : stmt -> int -> int64 -> rc
val bind_int : stmt -> int -> int -> rc
val bind_text : stmt -> int -> string -> rc
val bind_float : stmt -> int -> float -> rc
val bind_blob : stmt -> int -> bytes -> rc
val bind_zeroblob : stmt -> int -> int -> rc

val step : stmt -> rc

val column_int64 : stmt -> int -> int64
val column_int : stmt -> int -> int
(** Read an INTEGER column as an OCaml [int]. Raises [Invalid_argument] if the
    SQLite 64-bit integer is outside the OCaml [int] range; use
    {!column_int64} for full-width SQLite integers. *)
val column_text : stmt -> int -> string
val column_float : stmt -> int -> float
val column_blob : stmt -> int -> bytes
val column_is_null : stmt -> int -> bool
val column_count : stmt -> int
val column_name : stmt -> int -> string
val column_type_code : stmt -> int -> int
val data_count : stmt -> int
val statement_sql : stmt -> string
val expanded_sql : stmt -> string
val statement_readonly : stmt -> bool
val statement_busy : stmt -> bool

val changes : db -> int
val total_changes : db -> int
val last_insert_rowid : db -> int64
val error_code : db -> rc
val extended_error_code : db -> int
val error_message : db -> string
val autocommit : db -> bool
val database_readonly : db -> string -> bool
val busy_timeout : db -> int -> rc
val interrupt : db -> unit
val is_interrupted : db -> bool
val complete : string -> bool

val check : db -> operation:string -> rc -> (unit, error) result
val check_exn : db -> operation:string -> rc -> unit
(** Convert a result code to a structured error using the database's current
    SQLite diagnostic message. *)

val exec_result : db -> string -> (unit, error) result
val exec : db -> string -> unit
(** Execute a statement that returns no rows. [exec] raises {!Error}. *)

val exec_script_result : db -> string -> (unit, error) result
val exec_script : db -> string -> unit
(** Execute one or more SQL statements and ignore result rows. *)

val begin_transaction_result :
  ?mode:transaction_mode -> db -> (unit, error) result
val begin_transaction : ?mode:transaction_mode -> db -> unit
val commit_result : db -> (unit, error) result
val commit : db -> unit
val rollback_result : db -> (unit, error) result
val rollback : db -> unit
val with_transaction_result :
  ?mode:transaction_mode -> db -> (db -> ('a, error) result) -> ('a, error) result
val with_transaction : ?mode:transaction_mode -> db -> (db -> 'a) -> 'a

val savepoint_result : db -> string -> (unit, error) result
val savepoint : db -> string -> unit
val release_result : db -> string -> (unit, error) result
val release : db -> string -> unit
val rollback_to_result : db -> string -> (unit, error) result
val rollback_to : db -> string -> unit

val enable_load_extension : db -> bool -> rc
val load_extension_result : db -> string -> (unit, error) result
val load_extension : db -> string -> unit

val backup_to_path_result : db -> string -> (unit, error) result
val backup_to_path : db -> string -> unit
val restore_from_path_result : db -> string -> (unit, error) result
val restore_from_path : db -> string -> unit

val query_one_int_result : db -> string -> (int, error) result
val query_one_int : db -> string -> int
(** Small typed convenience used by tests and smoke probes. *)

module Config : sig
  type mode : immutable_data = open_mode =
    | Read_only
    | Read_write
    | Read_write_create

  type t : immutable_data = config = {
    path : string;
    mode : open_mode;
    busy_timeout_ms : int option;
    foreign_keys : bool;
    journal_mode : journal_mode option;
    synchronous : synchronous option;
    cache_size : int option;
  }

  val default : string -> t
  val in_memory : unit -> t
end

module Error : sig
  type t : immutable_data = error = {
    operation : string;
    code : rc;
    message : string;
  }

  val pp : Format.formatter -> t -> unit
  val to_string : t -> string
end

module Testing : sig
  val with_db : Config.t -> (db -> ('a, string) result) -> ('a, string) result
end
