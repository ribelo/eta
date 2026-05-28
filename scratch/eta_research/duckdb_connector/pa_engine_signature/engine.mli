(** Proposed ENGINE signature for generalizing Sql over multiple backends.

    This signature must be satisfiable by both SQLite and DuckDB without:
    - Changing public Sqlite types
    - Widening errors to a lossy union
    - Hiding prepared-statement semantics callers depend on
    - Wrapping every call in an extra box *)

(** Engine-specific error type. Each engine defines its own error taxonomy. *)
module type ERROR = sig
  type t

  val pp : Format.formatter -> t -> unit
  val to_string : t -> string
end

(** Engine-specific value type. Each engine defines its own value variant. *)
module type VALUE = sig
  type t =
    | Null
    | Int of int
    | Int64 of int64
    | Float of float
    | String of string
    | Bool of bool
    | Bytes of bytes
    (* Engine-specific extensions go here *)

  val null : t
  val int : int -> t
  val int64 : int64 -> t
  val float : float -> t
  val string : string -> t
  val bool : bool -> t
  val bytes : bytes -> t
end

(** The ENGINE signature — core database operations. *)
module type S = sig
  (** Engine-specific error type *)
  module Error : ERROR

  (** Engine-specific value type *)
  module Value : VALUE

  (** Database handle — heavy, process-scoped *)
  type database

  (** Connection handle — cheap, per-fiber *)
  type connection

  (** Prepared statement handle *)
  type statement

  (** Query result — engine-specific *)
  type result

  (** {2 Lifecycle} *)

  val open_database : string -> (database, Error.t) result
  val close_database : database -> (unit, Error.t) result
  val connect : database -> (connection, Error.t) result
  val disconnect : connection -> (unit, Error.t) result

  (** {2 Query Execution} *)

  val prepare : connection -> string -> (statement, Error.t) result
  val bind : statement -> int -> Value.t -> (unit, Error.t) result
  val step : statement -> (bool, Error.t) result  (** true = has row *)
  val reset : statement -> (unit, Error.t) result
  val finalize : statement -> (unit, Error.t) result

  val exec : connection -> string -> (unit, Error.t) result

  (** {2 Result Access} *)

  val column_count : statement -> int
  val column_name : statement -> int -> string
  val column_type : statement -> int -> int
  val column_int64 : statement -> int -> int64
  val column_double : statement -> int -> float
  val column_text : statement -> int -> string
  val column_blob : statement -> int -> bytes
  val column_is_null : statement -> int -> bool

  (** {3 Cancellation} *)

  val interrupt : connection -> unit

  (** {3 Thread Safety} *)

  val is_thread_safe : bool
end
