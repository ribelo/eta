(** LadybugDB graph connector for Eta. *)

module Value : sig
  type node = {
    id : int64 option;
    labels : string list;
    properties : (string * t) list;
  }

  and rel = {
    id : int64 option;
    src : int64 option;
    dst : int64 option;
    label : string option;
    properties : (string * t) list;
  }

  and path = {
    nodes : node list;
    rels : rel list;
  }

  and t =
    | Null
    | Bool of bool
    | Int of int64
    | Float of float
    | String of string
    | List of t list
    | Map of (string * t) list
    | Node of node
    | Rel of rel
    | Path of path
end

module Param : sig
  type t

  val null : string -> t
  val bool : string -> bool -> t
  val int : string -> int64 -> t
  val float : string -> float -> t
  val string : string -> string -> t
end

type database
type connection

type error_category =
  | Query_syntax
  | Type_mismatch
  | Integrity_violation
  | Timeout_or_interrupt
  | Connection_closed_or_invalid
  | Other

type error =
  | Library_unavailable of string
  | Driver_error of {
      operation : string;
      category : error_category;
      message : string;
    }
  | Invalid_value of string
  | Closed

exception Error of error

val pp_error : Format.formatter -> error -> unit
val show_error : error -> string
val available : unit -> (unit, error) result
val version : unit -> (string, error) result
val classify_error : string -> error_category

module Database : sig
  type t = database

  val open_ : path:string -> (t, error) result
  val open_memory : unit -> (t, error) result
  val close : t -> (unit, error) result
end

module Connection : sig
  type t = connection

  val connect : database -> (t, error) result
  val close : t -> (unit, error) result
  val interrupt : t -> unit
  val query_string : ?params:Param.t list -> t -> string -> (string, error) result
  val exec : ?params:Param.t list -> t -> string -> (unit, error) result
end

module Pool : sig
  type t

  type nonrec error =
    | Ladybug of error
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
    database ->
    (t, error) Eta.Effect.t

  val query_string :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    ?params:Param.t list ->
    t ->
    string ->
    (string, error) Eta.Effect.t

  val shutdown : ?deadline:Eta.Duration.t -> t -> (unit, error) Eta.Effect.t
  val stats : t -> Eta.Pool.stats
end
