(** Accepted ENGINE signature from the DuckDB P-A lab, copied here so this
    probe can prove Turso satisfies the same shape without depending on the
    production SQL package layout. *)

module type ERROR = sig
  type t

  val pp : Format.formatter -> t -> unit
  val to_string : t -> string
end

module type VALUE = sig
  type t =
    | Null
    | Int of int
    | Int64 of int64
    | Float of float
    | String of string
    | Bool of bool
    | Bytes of bytes

  val null : t
  val int : int -> t
  val int64 : int64 -> t
  val float : float -> t
  val string : string -> t
  val bool : bool -> t
  val bytes : bytes -> t
end

module type S = sig
  module Error : ERROR
  module Value : VALUE

  type database
  type connection
  type statement
  type result

  val open_database : string -> (database, Error.t) Stdlib.result
  val close_database : database -> (unit, Error.t) Stdlib.result
  val connect : database -> (connection, Error.t) Stdlib.result
  val disconnect : connection -> (unit, Error.t) Stdlib.result

  val prepare : connection -> string -> (statement, Error.t) Stdlib.result
  val bind : statement -> int -> Value.t -> (unit, Error.t) Stdlib.result
  val step : statement -> (bool, Error.t) Stdlib.result
  val reset : statement -> (unit, Error.t) Stdlib.result
  val finalize : statement -> (unit, Error.t) Stdlib.result

  val exec : connection -> string -> (unit, Error.t) Stdlib.result

  val column_count : statement -> int
  val column_name : statement -> int -> string
  val column_type : statement -> int -> int
  val column_int64 : statement -> int -> int64
  val column_double : statement -> int -> float
  val column_text : statement -> int -> string
  val column_blob : statement -> int -> bytes
  val column_is_null : statement -> int -> bool

  val interrupt : connection -> unit
  val is_thread_safe : bool
end
