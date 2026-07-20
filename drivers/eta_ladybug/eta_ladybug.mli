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
    | Struct of (string * t) list
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
  val struct_ : string -> (string * Value.t) list -> t
  val rows : string -> (string * Value.t) list list -> t
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

module Extension : sig
  type official

  type source =
    | Official
    | User
    | Static_link
    | Unknown of string

  type loaded = {
    name : string;
    source : source;
    path : string;
  }

  type available = {
    name : string;
    description : string;
  }

  val official : string -> (official, error) result
  val name : official -> string
  val algo : official
  val azure : official
  val delta : official
  val duckdb : official
  val fts : official
  val httpfs : official
  val iceberg : official
  val json : official
  val llm : official
  val neo4j : official
  val postgres : official
  val sqlite : official
  val unity_catalog : official
  val vector : official
end

module Database : sig
  type t = database

  val open_ : path:string -> (t, error) result
  val open_memory : unit -> (t, error) result
  val close : t -> (unit, error) result
end

module Connection : sig
  type t = connection

  type timed_error =
    | Ladybug of error
    | Timeout

  val connect : database -> (t, error) result
  val close : t -> (unit, error) result
  val interrupt : t -> unit
  (** [classify_read_only conn cypher] prepares [cypher] and reports LadybugDB's
      read-only classification. [Ok true] means read-only, [Ok false] means
      mutating, and [Error _] means prepare failed. *)
  val classify_read_only : t -> string -> (bool, error) result
  val query_string : ?params:Param.t list -> t -> string -> (string, error) result
  val query_rows :
    ?params:Param.t list -> t -> string -> (Row.t list, error) result
  (** Execute Cypher and return engine-named dynamic rows without a typed
      decoder. *)
  val query : t -> 'a Query.t -> ('a list, error) result
  val exec : ?params:Param.t list -> t -> string -> (unit, error) result
  val query_string_with_timeout :
    ?blocking_pool:Eta_blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    ?params:Param.t list ->
    t ->
    string ->
    (string, timed_error) Eta.Effect.t
  val query_rows_with_timeout :
    ?blocking_pool:Eta_blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    ?params:Param.t list ->
    t ->
    string ->
    (Row.t list, timed_error) Eta.Effect.t
  val query_with_timeout :
    ?blocking_pool:Eta_blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    t ->
    'a Query.t ->
    ('a list, timed_error) Eta.Effect.t
  val exec_with_timeout :
    ?blocking_pool:Eta_blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    ?params:Param.t list ->
    t ->
    string ->
    (unit, timed_error) Eta.Effect.t
  val install_extension :
    ?repo:string -> ?force:bool -> t -> Extension.official -> (unit, error) result
  val update_extension : t -> Extension.official -> (unit, error) result
  val uninstall_extension : t -> Extension.official -> (unit, error) result
  val load_extension : t -> Extension.official -> (unit, error) result
  val load_extension_path : t -> path:string -> (unit, error) result
  val loaded_extensions : t -> (Extension.loaded list, error) result
  val official_extensions : t -> (Extension.available list, error) result
  val begin_transaction : t -> (unit, error) result
  val commit : t -> (unit, error) result
  val rollback : t -> (unit, error) result
  val transaction : t -> (t -> ('a, error) result) -> ('a, error) result
end

module Pool : sig
  type t
  type driver_error = error

  type nonrec error =
    | Ladybug of driver_error
    | Pool_shutdown
    | Pool_shutdown_timeout
    | Timeout

  val create :
    ?blocking_pool:Eta_blocking.Pool.t ->
    ?name:string ->
    ?max_size:int ->
    ?max_idle:int ->
    ?idle_lifetime:Eta.Duration.t ->
    ?max_lifetime:Eta.Duration.t ->
    database ->
    (t, error) Eta.Effect.t

  val query_string :
    ?blocking_pool:Eta_blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    ?params:Param.t list ->
    t ->
    string ->
    (string, error) Eta.Effect.t

  val query :
    ?blocking_pool:Eta_blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    t ->
    'a Query.t ->
    ('a list, error) Eta.Effect.t

  val install_extension :
    ?blocking_pool:Eta_blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    ?repo:string ->
    ?force:bool ->
    t ->
    Extension.official ->
    (unit, error) Eta.Effect.t

  val update_extension :
    ?blocking_pool:Eta_blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    t ->
    Extension.official ->
    (unit, error) Eta.Effect.t

  val uninstall_extension :
    ?blocking_pool:Eta_blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    t ->
    Extension.official ->
    (unit, error) Eta.Effect.t

  val load_extension :
    ?blocking_pool:Eta_blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    t ->
    Extension.official ->
    (unit, error) Eta.Effect.t

  val load_extension_path :
    ?blocking_pool:Eta_blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    t ->
    path:string ->
    (unit, error) Eta.Effect.t

  val loaded_extensions :
    ?blocking_pool:Eta_blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    t ->
    (Extension.loaded list, error) Eta.Effect.t

  val official_extensions :
    ?blocking_pool:Eta_blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    t ->
    (Extension.available list, error) Eta.Effect.t

  val transaction :
    ?blocking_pool:Eta_blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    t ->
    (Connection.t -> ('a, driver_error) result) ->
    ('a, error) Eta.Effect.t

  val shutdown : ?deadline:Eta.Duration.t -> t -> (unit, error) Eta.Effect.t
  val stats : t -> Eta.Pool.stats
end
