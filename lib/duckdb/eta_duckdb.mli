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
  | Decode_error of {
      operation : string;
      message : string;
    }
  | Invalid_value of string
  | Closed

exception Error of error

include Eta_sql_dsl.S with type value := Value.t and type row := Row.t and type error := error

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
  val select : t -> 'a Compiled.select -> ('a list, error) result
  val returning : t -> 'a Compiled.returning -> ('a list, error) result
  val execute : t -> string -> Value.t list -> (int, error) result
  val execute_compiled : t -> Compiled.change -> (int, error) result
  val exec_script : t -> string -> (unit, error) result
  val run_schema : t -> Compiled.schema -> (unit, error) result
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

module Bulk_row : sig
  type t

  val empty : t
  val value : ('table, 'a) column -> 'a -> t -> t
  val null : ('table, 'a option) column -> t -> t
end

module Bulk : sig
  type 'table t

  val create : ?schema:string -> connection -> 'table table -> ('table t, error) result
  val append_row : 'table t -> Bulk_row.t -> (unit, error) result
  val flush : 'table t -> (unit, error) result
  val close : 'table t -> (unit, error) result
  val with_appender :
    ?schema:string ->
    connection ->
    'table table ->
    ('table t -> ('a, error) result) ->
    ('a, error) result
end

module Pool : sig
  type t

  type nonrec error =
    | Duckdb of error
    | Invalid_blocking_pool of string
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
  (** Create a DuckDB pool. Per-operation [timeout] values bound the Eta
      caller's wait through {!Eta.Effect.blocking_result_timeout}; they do not
      forcibly preempt a started DuckDB C call in a [Drain] blocking pool. Use a
      DuckDB-level cancellation mechanism when the underlying call must stop
      independently. [Detach_started] blocking pools are rejected for pooled
      operations because a detached worker could keep using a leased connection
      after the pool returns it to another caller. *)

  val with_connection :
    t -> (connection -> ('a, error) Eta.Effect.t) -> ('a, error) Eta.Effect.t

  val query :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    t ->
    string ->
    Value.t list ->
    (Row.t list, error) Eta.Effect.t

  val select :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    t ->
    'a Compiled.select ->
    ('a list, error) Eta.Effect.t

  val returning :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    t ->
    'a Compiled.returning ->
    ('a list, error) Eta.Effect.t

  val execute :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    t ->
    string ->
    Value.t list ->
    (int, error) Eta.Effect.t

  val execute_compiled :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    t ->
    Compiled.change ->
    (int, error) Eta.Effect.t

  val run_schema :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    t ->
    Compiled.schema ->
    (unit, error) Eta.Effect.t

  val shutdown : ?deadline:Eta.Duration.t -> t -> (unit, error) Eta.Effect.t
  val stats : t -> Eta.Pool.stats
end
