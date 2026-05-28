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

module Row : sig
  type t = (string * Value.t) list

  val get : string -> t -> Value.t option
  val fields : t -> string list
  val string : string -> t -> string option
  val int : string -> t -> int64 option
  val bool : string -> t -> bool option
  val float : string -> t -> float option
  val node : string -> t -> Value.node option
end

module Param : sig
  type t

  val null : string -> t
  val bool : string -> bool -> t
  val int : string -> int64 -> t
  val float : string -> float -> t
  val string : string -> string -> t
  val list : string -> Value.t list -> t
  val map : string -> (string * Value.t) list -> t
end

module Decode : sig
  type 'a t

  val run : 'a t -> Row.t -> ('a, string) result
  val value : string -> Value.t t
  val string : string -> string t
  val int : string -> int64 t
  val bool : string -> bool t
  val float : string -> float t
  val node : string -> Value.node t
  val map : ('a -> 'b) -> 'a t -> 'b t
  val tuple2 : 'a t -> 'b t -> ('a * 'b) t
  val tuple3 : 'a t -> 'b t -> 'c t -> ('a * 'b * 'c) t
end

module Expr : sig
  type operand
  type t

  val raw : string -> t
  val raw_operand : string -> operand
  val property : string -> string -> operand
  val param : string -> operand
  val eq : operand -> operand -> t
  val ne : operand -> operand -> t
  val gt : operand -> operand -> t
  val ge : operand -> operand -> t
  val lt : operand -> operand -> t
  val le : operand -> operand -> t
  val and_ : t -> t -> t
  val or_ : t -> t -> t
  val not_ : t -> t
end

module Pattern : sig
  type direction =
    | Out
    | In
    | Undirected

  type hops =
    | One
    | Range of int option * int option

  type t

  val node :
    ?as_:string -> ?labels:string list -> ?props:(string * string) list -> unit -> t
  val anon_node : ?labels:string list -> ?props:(string * string) list -> unit -> t
  val rel :
    ?as_:string ->
    ?label:string ->
    ?direction:direction ->
    ?hops:hops ->
    ?props:(string * string) list ->
    unit ->
    t
  val path : ?as_:string -> t list -> t
  val raw : string -> t
  val to_cypher : t -> string
end

module Query : sig
  type 'a t
  type builder

  val raw : ?params:Param.t list -> cypher:string -> decode:'a Decode.t -> unit -> 'a t
  val match_ : Pattern.t -> builder
  val optional : Pattern.t -> builder -> builder
  val where : Expr.t -> builder -> builder
  val with_ : string list -> builder -> builder
  val raw_clause : string -> builder -> builder
  val with_params : Param.t list -> builder -> builder
  val order_by : ?desc:bool -> string -> builder -> builder
  val limit : int -> builder -> builder
  val returning : string list -> decode:'a Decode.t -> builder -> 'a t
  val cypher : 'a t -> string
  val params : 'a t -> Param.t list
  val decode : 'a t -> 'a Decode.t
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
  | Decode_error of {
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
  val query : t -> 'a Query.t -> ('a list, error) result
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

  val query :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    t ->
    'a Query.t ->
    ('a list, error) Eta.Effect.t

  val shutdown : ?deadline:Eta.Duration.t -> t -> (unit, error) Eta.Effect.t
  val stats : t -> Eta.Pool.stats
end
