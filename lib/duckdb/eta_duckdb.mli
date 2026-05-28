(** DuckDB connector for Eta. *)

module Value : sig
  type t =
    | Null
    | Bool of bool
    | Int of int
    | Int64 of int64
    | Float of float
    | String of string
    | Bytes of bytes
    | Decimal of string
    | Date of string
    | Time of string
    | Timestamp of string
    | Uuid of string
    | Json of string
    | Enum of string
    | List of t list
    | Struct of (string * t) list

  val to_string : t -> string
end

module Row : sig
  type t = (string * Value.t) list

  val get : string -> t -> Value.t option
  val fields : t -> string list
  val int : string -> t -> int option
  val int64 : string -> t -> int64 option
  val string : string -> t -> string option
  val bool : string -> t -> bool option
  val float : string -> t -> float option
  val bytes : string -> t -> bytes option
end

type database
type connection
type appender

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
  | Invalid_value of string
  | Closed

exception Error of error

val pp_error : Format.formatter -> error -> unit
val show_error : error -> string
val available : unit -> (unit, error) result
val version : unit -> (string, error) result

module Database : sig
  type t = database

  val open_ : config -> (t, error) result
  val open_memory : unit -> (t, error) result
  val close : t -> (unit, error) result
end

module Connection : sig
  type t = connection

  val connect : database -> (t, error) result
  val close : t -> (unit, error) result
  val interrupt : t -> unit
  val query : t -> string -> Value.t list -> (Row.t list, error) result
  val execute : t -> string -> Value.t list -> (int, error) result
  val exec_script : t -> string -> (unit, error) result
  val begin_transaction : ?mode:transaction_mode -> t -> (unit, error) result
  val commit : t -> (unit, error) result
  val rollback : t -> (unit, error) result
  val transaction :
    ?mode:transaction_mode -> t -> (t -> ('a, error) result) -> ('a, error) result
end

module Appender : sig
  type t = appender

  val create :
    ?schema:string -> connection -> table:string -> (t, error) result
  val append_row : t -> Value.t list -> (unit, error) result
  val flush : t -> (unit, error) result
  val close : t -> (unit, error) result
  val with_appender :
    ?schema:string ->
    connection ->
    table:string ->
    (t -> ('a, error) result) ->
    ('a, error) result
end

module Pool : sig
  type t

  type nonrec error =
    | Duckdb of error
    | Pool_shutdown
    | Pool_shutdown_timeout
    | Timeout

  val create :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    ?name:string ->
    ?max_size:int ->
    ?max_idle:int ->
    ?idle_lifetime:Eta.Duration.t ->
    ?max_lifetime:Eta.Duration.t ->
    config ->
    (t, error) Eta.Effect.t

  val with_connection :
    t -> (connection -> ('a, error) Eta.Effect.t) -> ('a, error) Eta.Effect.t

  val query :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    t ->
    string ->
    Value.t list ->
    (Row.t list, error) Eta.Effect.t

  val execute :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    t ->
    string ->
    Value.t list ->
    (int, error) Eta.Effect.t

  val shutdown : ?deadline:Eta.Duration.t -> t -> (unit, error) Eta.Effect.t
  val stats : t -> Eta.Pool.stats
end
