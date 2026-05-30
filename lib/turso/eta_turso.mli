(** Turso connector for Eta.

    Turso is treated as the SQLite-compatible Rust engine exposed through
    [libturso_sqlite3], not as libSQL. This package loads that C API at runtime
    so installing Eta itself never pulls Turso into the root package closure. *)

module Value = Eta_sql.Value
module Row = Eta_sql.Row

type db
type stmt
type rc = private int

type open_mode =
  | Read_only
  | Read_write
  | Read_write_create

type journal_mode =
  | Mvcc
  | Wal

type config = {
  path : string;
  mode : open_mode;
  busy_timeout_ms : int option;
  foreign_keys : bool;
  journal_mode : journal_mode;
}

type transaction_mode =
  | Read
  | Write
  | Concurrent

type error =
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

val pp_error : Format.formatter -> error -> unit
val show_error : error -> string
val available : unit -> (unit, error) result

val default_config : string -> config
val open_ : config -> (db, error) result
val open_exn : config -> db
val close : db -> (unit, error) result
val close_exn : db -> unit

val prepare : db -> string -> (stmt, error) result
val finalize : stmt -> (unit, error) result
val step : stmt -> rc

val query : db -> string -> Value.t list -> (Row.t list, error) result
val execute : db -> string -> Value.t list -> (int, error) result
val exec_script : db -> string -> (unit, error) result

val begin_transaction : ?mode:transaction_mode -> db -> (unit, error) result
val commit : db -> (unit, error) result
val rollback : db -> (unit, error) result
val transaction :
  ?mode:transaction_mode -> db -> (db -> ('a, error) result) -> ('a, error) result

val retry_on_conflict :
  max_attempts:int ->
  backoff:(attempt:int -> unit) ->
  (unit -> ('a, error) result) ->
  ('a, error) result

type 'a typ

val int : int typ
val int64 : int64 typ
val text : string typ
val bool : bool typ
val float : float typ
val blob : bytes typ
val nullable : 'a typ -> 'a option typ

module Compiled : sig
  type 'a select
  type 'a returning
  type change
  type schema

  val select_sql : 'a select -> string
  val select_params : 'a select -> Value.t list
  val returning_sql : 'a returning -> string
  val returning_params : 'a returning -> Value.t list
  val change_sql : change -> string
  val change_params : change -> Value.t list
  val schema_sql : schema -> string
end

type 'table table
type ('table, 'a) column

module Table : sig
  type 'table t = 'table table

  module Make (_ : sig
    val name : string
  end) : sig
    type table

    val table : table t
    val column : string -> 'a typ -> (table, 'a) column
  end

  val name : 'table t -> string
  val alias : 'table t -> string -> 'table t
  val column : 'table t -> string -> 'a typ -> ('table, 'a) column
end

module Column : sig
  type ('table, 'a) t = ('table, 'a) column

  val name : (_, _) t -> string
  val table_name : (_, _) t -> string
end

module Expr : sig
  type ('scope, 'a) t

  val true_ : ('scope, bool) t
  val false_ : ('scope, bool) t
  val lit : 'a typ -> 'a -> ('scope, 'a) t
  val int_lit : int -> ('scope, int) t
  val int64_lit : int64 -> ('scope, int64) t
  val float_lit : float -> ('scope, float) t
  val text_lit : string -> ('scope, string) t
  val bool_lit : bool -> ('scope, bool) t
  val col : ('scope, 'a) column -> ('scope, 'a) t
  val eq : ('scope, 'a) column -> 'a -> ('scope, bool) t
  val ne : ('scope, 'a) column -> 'a -> ('scope, bool) t
  val gt : ('scope, 'a) column -> 'a -> ('scope, bool) t
  val ge : ('scope, 'a) column -> 'a -> ('scope, bool) t
  val lt : ('scope, 'a) column -> 'a -> ('scope, bool) t
  val le : ('scope, 'a) column -> 'a -> ('scope, bool) t
  val like : ('scope, string) column -> string -> ('scope, bool) t
  val eq_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
  val ne_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
  val gt_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
  val ge_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
  val lt_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
  val le_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
  val eq_col : ('scope, 'a) column -> ('scope, 'a) column -> ('scope, bool) t
  val gt_col : ('scope, 'a) column -> ('scope, 'a) column -> ('scope, bool) t
  val ge_col : ('scope, 'a) column -> ('scope, 'a) column -> ('scope, bool) t
  val lt_col : ('scope, 'a) column -> ('scope, 'a) column -> ('scope, bool) t
  val le_col : ('scope, 'a) column -> ('scope, 'a) column -> ('scope, bool) t
  val add : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, 'a) t
  val sub : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, 'a) t
  val mul : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, 'a) t
  val div : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, 'a) t
  val is_null : ('scope, 'a option) column -> ('scope, bool) t
  val is_not_null : ('scope, 'a option) column -> ('scope, bool) t
  val between : ('scope, 'a) column -> 'a -> 'a -> ('scope, bool) t
  val in_values : ('scope, 'a) column -> 'a list -> ('scope, bool) t
  val in_select : ('scope, 'a) column -> 'a Compiled.select -> ('scope, bool) t
  val exists : _ Compiled.select -> ('scope, bool) t
  val count : unit -> ('scope, int) t
  val sum_int : ('scope, int) column -> ('scope, int) t
  val sum_float : ('scope, float) column -> ('scope, float) t
  val avg : ('scope, 'a) column -> ('scope, float) t
  val min : ('scope, 'a) column -> ('scope, 'a) t
  val max : ('scope, 'a) column -> ('scope, 'a) t
  val case : (('scope, bool) t * ('scope, 'a) t) list -> default:('scope, 'a) t -> ('scope, 'a) t
  val and_ : ('scope, bool) t -> ('scope, bool) t -> ('scope, bool) t
  val or_ : ('scope, bool) t -> ('scope, bool) t -> ('scope, bool) t
  val not_ : ('scope, bool) t -> ('scope, bool) t
end

module Projection : sig
  type ('scope, 'a) t

  val one : ('scope, 'a) column -> ('scope, 'a) t
  val expr : ?as_:string -> ('scope, 'a) Expr.t -> ('scope, 'a) t
  val t2 : ('scope, 'a) t -> ('scope, 'b) t -> ('scope, 'a * 'b) t
  val t3 :
    ('scope, 'a) t ->
    ('scope, 'b) t ->
    ('scope, 'c) t ->
    ('scope, 'a * 'b * 'c) t
  val t4 :
    ('scope, 'a) t ->
    ('scope, 'b) t ->
    ('scope, 'c) t ->
    ('scope, 'd) t ->
    ('scope, 'a * 'b * 'c * 'd) t
  val t5 :
    ('scope, 'a) t ->
    ('scope, 'b) t ->
    ('scope, 'c) t ->
    ('scope, 'd) t ->
    ('scope, 'e) t ->
    ('scope, 'a * 'b * 'c * 'd * 'e) t
  val t6 :
    ('scope, 'a) t ->
    ('scope, 'b) t ->
    ('scope, 'c) t ->
    ('scope, 'd) t ->
    ('scope, 'e) t ->
    ('scope, 'f) t ->
    ('scope, 'a * 'b * 'c * 'd * 'e * 'f) t
  val t7 :
    ('scope, 'a) t ->
    ('scope, 'b) t ->
    ('scope, 'c) t ->
    ('scope, 'd) t ->
    ('scope, 'e) t ->
    ('scope, 'f) t ->
    ('scope, 'g) t ->
    ('scope, 'a * 'b * 'c * 'd * 'e * 'f * 'g) t
  val t8 :
    ('scope, 'a) t ->
    ('scope, 'b) t ->
    ('scope, 'c) t ->
    ('scope, 'd) t ->
    ('scope, 'e) t ->
    ('scope, 'f) t ->
    ('scope, 'g) t ->
    ('scope, 'h) t ->
    ('scope, 'a * 'b * 'c * 'd * 'e * 'f * 'g * 'h) t
  val count : ?as_:string -> unit -> ('scope, int) t
  val sum_int : ?as_:string -> ('scope, int) column -> ('scope, int) t
  val sum_float : ?as_:string -> ('scope, float) column -> ('scope, float) t
  val avg : ?as_:string -> ('scope, 'a) column -> ('scope, float) t
  val min : ?as_:string -> ('scope, 'a) column -> ('scope, 'a) t
  val max : ?as_:string -> ('scope, 'a) column -> ('scope, 'a) t
  val row_number :
    ?as_:string ->
    ?partition_by:('scope, 'a) column list ->
    ?order_by:('scope, 'b) column ->
    unit ->
    ('scope, int) t
  val map : ('a -> 'b) -> ('scope, 'a) t -> ('scope, 'b) t
end

module Scope : sig
  type ('sub, 'super) contains

  val self : ('scope, 'scope) contains
  val left : ('sub, 'super) contains -> ('sub, 'super * 'added) contains
  val right : ('added, 'existing * 'added) contains
  val column : ('sub, 'super) contains -> ('sub, 'a) column -> ('super, 'a) column
end

module Source : sig
  type 'scope t

  val from : 'table table -> 'table t
  val join :
    ?op:[ `Inner | `Left ] ->
    on:('existing * 'added, bool) Expr.t ->
    'added table ->
    'existing t ->
    ('existing * 'added) t
end

module Select : sig
  type ('scope, 'a) t

  val from : 'table table -> ('table, 'a) Projection.t -> ('table, 'a) t
  val from_source : 'scope Source.t -> ('scope, 'a) Projection.t -> ('scope, 'a) t
  val with_cte : name:string -> _ Compiled.select -> ('scope, 'a) t -> ('scope, 'a) t
  val distinct : ('scope, 'a) t -> ('scope, 'a) t
  val where : ('scope, bool) Expr.t -> ('scope, 'a) t -> ('scope, 'a) t
  val group_by : ('scope, 'b) column -> ('scope, 'a) t -> ('scope, 'a) t
  val group_by_many : ('scope, 'b) column list -> ('scope, 'a) t -> ('scope, 'a) t
  val having : ('scope, bool) Expr.t -> ('scope, 'a) t -> ('scope, 'a) t
  val order_by : ?desc:bool -> ('scope, 'b) column -> ('scope, 'a) t -> ('scope, 'a) t
  val limit : int -> ('scope, 'a) t -> ('scope, 'a) t
  val to_sql : (_, _) t -> string
  val compile : (_, 'a) t -> 'a Compiled.select
end

module Insert : sig
  type 'table t

  val into : 'table table -> 'table t
  val value : ('table, 'a) column -> 'a -> 'table t -> 'table t
  val on_conflict_do_nothing : ('table, 'a) column list -> 'table t -> 'table t
  val on_conflict_update :
    ('table, 'a) column list -> set:('table, 'b) column list -> 'table t -> 'table t
  val to_sql : _ t -> string
  val compile : _ t -> Compiled.change
  val returning : ('table, 'a) Projection.t -> 'table t -> 'a Compiled.returning
end

module Update : sig
  type 'table t

  val table : 'table table -> 'table t
  val set : ('table, 'a) column -> 'a -> 'table t -> 'table t
  val where : ('table, bool) Expr.t -> 'table t -> 'table t
  val to_sql : _ t -> string
  val compile : _ t -> Compiled.change
  val returning : ('table, 'a) Projection.t -> 'table t -> 'a Compiled.returning
end

module Delete : sig
  type 'table t

  val from : 'table table -> 'table t
  val where : ('table, bool) Expr.t -> 'table t -> 'table t
  val to_sql : _ t -> string
  val compile : _ t -> Compiled.change
  val returning : ('table, 'a) Projection.t -> 'table t -> 'a Compiled.returning
end

module Eta_schema : sig
  type reference
  type column_def
  type t

  val references : ?on_delete:string -> ?on_update:string -> (_, _) column -> reference
  val column :
    ?primary_key:bool ->
    ?not_null:bool ->
    ?unique:bool ->
    ?default:string ->
    ?references:reference ->
    (_, _) column ->
    column_def
  val create_table : ?if_not_exists:bool -> 'table table -> column_def list -> t
  val drop_table : ?if_exists:bool -> 'table table -> t
  val create_index :
    ?unique:bool ->
    ?if_not_exists:bool ->
    name:string ->
    'table table ->
    (_, _) column list ->
    t
  val to_sql : t -> string
  val compile : t -> Compiled.schema
end

val select : db -> 'a Compiled.select -> ('a list, error) result
val returning : db -> 'a Compiled.returning -> ('a list, error) result
val execute_compiled : db -> Compiled.change -> (int, error) result
val run_schema : db -> Compiled.schema -> (unit, error) result

module Pool : sig
  type t

  type nonrec error =
    | Turso of error
    | Pool_shutdown
    | Pool_shutdown_timeout
    | Timeout

  val pp_error : Format.formatter -> error -> unit

  val create :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    ?name:string ->
    ?max_size:int ->
    ?max_idle:int ->
    ?idle_lifetime:Eta.Duration.t ->
    ?max_lifetime:Eta.Duration.t ->
    config ->
    (t, error) Eta.Effect.t

  val with_db :
    t ->
    (db -> ('a, error) Eta.Effect.t) ->
    ('a, error) Eta.Effect.t

  val query :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    t ->
    string ->
    Value.t list ->
    (Row.t list, error) Eta.Effect.t

  val select :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    t ->
    'a Compiled.select ->
    ('a list, error) Eta.Effect.t

  val returning :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    t ->
    'a Compiled.returning ->
    ('a list, error) Eta.Effect.t

  val execute :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    t ->
    string ->
    Value.t list ->
    (int, error) Eta.Effect.t

  val execute_compiled :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    t ->
    Compiled.change ->
    (int, error) Eta.Effect.t

  val run_schema :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    t ->
    Compiled.schema ->
    (unit, error) Eta.Effect.t

  val shutdown : ?deadline:Eta.Duration.t -> t -> (unit, error) Eta.Effect.t
  val stats : t -> Eta.Pool.stats
end
