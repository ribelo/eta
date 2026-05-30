(** Typed SQL query builder and SQLite-oriented SQL utilities for Eta.

    This is not an ORM. Applications define tables, columns, queries, and
    migrations explicitly; Eta owns rendering, binding, execution, and result
    decoding. *)

module Sqlite = Sqlite

type error =
  | Sqlite of Sqlite.error
  | Pool_error of string
  | Invalid_query of string
  | Decode_error of {
      operation : string;
      message : string;
    }

val pp_error : Format.formatter -> error -> unit
val show_error : error -> string

type sql_error = error

exception Error of error

type 'a typ

val int : int typ
val int64 : int64 typ
val text : string typ
val bool : bool typ
val float : float typ
val blob : bytes typ
val nullable : 'a typ -> 'a option typ

module Value : sig
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
  val to_int : t -> int option
  val to_int64 : t -> int64 option
  val to_float : t -> float option
  val to_string_value : t -> string option
  val to_bool : t -> bool option
  val to_bytes : t -> bytes option
  val is_null : t -> bool
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
end

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
  val to_string : t -> string
  val equal : t -> t -> bool
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
  (** [alias table name] renders [table AS name] in sources and qualifies
      columns created from the alias with [name]. *)

  val column : 'table t -> string -> 'a typ -> ('table, 'a) column
  (** Create a column value bound to a table value, including aliases. *)
end

module Column : sig
  type ('table, 'a) t = ('table, 'a) column

  val name : (_, _) t -> string
  val table_name : (_, _) t -> string
end

module Expr : sig
  type ('scope, 'a) t
  (** A typed SQL expression visible in ['scope] and decoding/rendering as ['a]. *)

  val true_ : ('scope, bool) t
  (** SQL true predicate. *)
  val false_ : ('scope, bool) t
  (** SQL false predicate. *)
  val lit : 'a typ -> 'a -> ('scope, 'a) t
  (** Parameterized literal with an explicit SQL type. *)
  val int_lit : int -> ('scope, int) t
  (** Parameterized integer literal. *)
  val int64_lit : int64 -> ('scope, int64) t
  (** Parameterized 64-bit integer literal. *)
  val float_lit : float -> ('scope, float) t
  (** Parameterized float literal. *)
  val text_lit : string -> ('scope, string) t
  (** Parameterized text literal. *)
  val bool_lit : bool -> ('scope, bool) t
  (** Parameterized boolean literal. *)
  val col : ('scope, 'a) column -> ('scope, 'a) t
  (** Treat a visible column as a typed expression. *)
  val eq : ('scope, 'a) column -> 'a -> ('scope, bool) t
  (** Column equals literal. *)
  val ne : ('scope, 'a) column -> 'a -> ('scope, bool) t
  (** Column does not equal literal. *)
  val gt : ('scope, 'a) column -> 'a -> ('scope, bool) t
  (** Column is greater than literal. *)
  val ge : ('scope, 'a) column -> 'a -> ('scope, bool) t
  (** Column is greater than or equal to literal. *)
  val lt : ('scope, 'a) column -> 'a -> ('scope, bool) t
  (** Column is less than literal. *)
  val le : ('scope, 'a) column -> 'a -> ('scope, bool) t
  (** Column is less than or equal to literal. *)
  val like : ('scope, string) column -> string -> ('scope, bool) t
  (** Text column matches a SQL LIKE pattern. *)
  val eq_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
  (** Expression equals expression. *)
  val ne_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
  (** Expression does not equal expression. *)
  val gt_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
  (** Expression is greater than expression. *)
  val ge_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
  (** Expression is greater than or equal to expression. *)
  val lt_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
  (** Expression is less than expression. *)
  val le_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
  (** Expression is less than or equal to expression. *)
  val eq_col : ('scope, 'a) column -> ('scope, 'a) column -> ('scope, bool) t
  (** Column equals column. *)
  val gt_col : ('scope, 'a) column -> ('scope, 'a) column -> ('scope, bool) t
  (** Column is greater than column. *)
  val ge_col : ('scope, 'a) column -> ('scope, 'a) column -> ('scope, bool) t
  (** Column is greater than or equal to column. *)
  val lt_col : ('scope, 'a) column -> ('scope, 'a) column -> ('scope, bool) t
  (** Column is less than column. *)
  val le_col : ('scope, 'a) column -> ('scope, 'a) column -> ('scope, bool) t
  (** Column is less than or equal to column. *)
  val add : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, 'a) t
  (** SQL addition over same-typed expressions. *)
  val sub : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, 'a) t
  (** SQL subtraction over same-typed expressions. *)
  val mul : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, 'a) t
  (** SQL multiplication over same-typed expressions. *)
  val div : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, 'a) t
  (** SQL division over same-typed expressions. *)
  val is_null : ('scope, 'a option) column -> ('scope, bool) t
  (** Nullable column is NULL. *)
  val is_not_null : ('scope, 'a option) column -> ('scope, bool) t
  (** Nullable column is not NULL. *)
  val between : ('scope, 'a) column -> 'a -> 'a -> ('scope, bool) t
  (** Column lies between two literal bounds. *)
  val in_values : ('scope, 'a) column -> 'a list -> ('scope, bool) t
  (** Column is in a non-empty literal list. *)
  val in_select : ('scope, 'a) column -> 'a Compiled.select -> ('scope, bool) t
  (** Column is in a typed subquery result. *)
  val exists : _ Compiled.select -> ('scope, bool) t
  (** SQL EXISTS predicate for a compiled subquery. *)
  val count : unit -> ('scope, int) t
  (** COUNT-star aggregate expression. *)
  val sum_int : ('scope, int) column -> ('scope, int) t
  (** SUM aggregate over an integer column. *)
  val sum_float : ('scope, float) column -> ('scope, float) t
  (** SUM aggregate over a float column. *)
  val avg : ('scope, 'a) column -> ('scope, float) t
  (** AVG aggregate over a numeric SQLite column. *)
  val min : ('scope, 'a) column -> ('scope, 'a) t
  (** MIN aggregate preserving the column type. *)
  val max : ('scope, 'a) column -> ('scope, 'a) t
  (** MAX aggregate preserving the column type. *)
  val case :
    (('scope, bool) t * ('scope, 'a) t) list ->
    default:('scope, 'a) t ->
    ('scope, 'a) t
  (** CASE WHEN expression with same-typed result branches. *)
  val and_ : ('scope, bool) t -> ('scope, bool) t -> ('scope, bool) t
  (** Boolean AND. *)
  val or_ : ('scope, bool) t -> ('scope, bool) t -> ('scope, bool) t
  (** Boolean OR. *)
  val not_ : ('scope, bool) t -> ('scope, bool) t
  (** Boolean NOT. *)
end

module Projection : sig
  type ('scope, 'a) t
  (** A SELECT projection visible in ['scope] and decoding one output value ['a]. *)

  val one : ('scope, 'a) column -> ('scope, 'a) t
  (** Project one visible column. *)
  val expr : ?as_:string -> ('scope, 'a) Expr.t -> ('scope, 'a) t
  (** Project any typed expression, optionally assigning a SQL alias. *)
  val t2 : ('scope, 'a) t -> ('scope, 'b) t -> ('scope, 'a * 'b) t
  (** Combine two projections into a pair. *)
  val t3 :
    ('scope, 'a) t ->
    ('scope, 'b) t ->
    ('scope, 'c) t ->
    ('scope, 'a * 'b * 'c) t
  (** Combine three projections into a tuple. *)
  val count : ?as_:string -> unit -> ('scope, int) t
  (** Project COUNT-star. *)
  val sum_int : ?as_:string -> ('scope, int) column -> ('scope, int) t
  (** Project SUM over an integer column. *)
  val sum_float : ?as_:string -> ('scope, float) column -> ('scope, float) t
  (** Project SUM over a float column. *)
  val avg : ?as_:string -> ('scope, 'a) column -> ('scope, float) t
  (** Project AVG over a numeric SQLite column. *)
  val min : ?as_:string -> ('scope, 'a) column -> ('scope, 'a) t
  (** Project MIN preserving the column type. *)
  val max : ?as_:string -> ('scope, 'a) column -> ('scope, 'a) t
  (** Project MAX preserving the column type. *)
  val row_number :
    ?as_:string ->
    ?partition_by:('scope, 'a) column list ->
    ?order_by:('scope, 'b) column ->
    unit ->
    ('scope, int) t
  (** Project ROW_NUMBER() with optional partition and order clauses. *)
  val t4 :
    ('scope, 'a) t ->
    ('scope, 'b) t ->
    ('scope, 'c) t ->
    ('scope, 'd) t ->
    ('scope, 'a * 'b * 'c * 'd) t
  (** Combine four projections into a tuple. *)
  val t5 :
    ('scope, 'a) t ->
    ('scope, 'b) t ->
    ('scope, 'c) t ->
    ('scope, 'd) t ->
    ('scope, 'e) t ->
    ('scope, 'a * 'b * 'c * 'd * 'e) t
  (** Combine five projections into a tuple. *)
  val t6 :
    ('scope, 'a) t ->
    ('scope, 'b) t ->
    ('scope, 'c) t ->
    ('scope, 'd) t ->
    ('scope, 'e) t ->
    ('scope, 'f) t ->
    ('scope, 'a * 'b * 'c * 'd * 'e * 'f) t
  (** Combine six projections into a tuple. *)
  val t7 :
    ('scope, 'a) t ->
    ('scope, 'b) t ->
    ('scope, 'c) t ->
    ('scope, 'd) t ->
    ('scope, 'e) t ->
    ('scope, 'f) t ->
    ('scope, 'g) t ->
    ('scope, 'a * 'b * 'c * 'd * 'e * 'f * 'g) t
  (** Combine seven projections into a tuple. *)
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
  (** Combine eight projections into a tuple. *)
  val map : ('a -> 'b) -> ('scope, 'a) t -> ('scope, 'b) t
  (** Map the decoded value while preserving the SQL projection. *)
end

module Scope : sig
  type ('sub, 'super) contains
  (** Evidence that ['super] contains every table visible in ['sub]. *)

  val self : ('scope, 'scope) contains
  (** A scope contains itself. *)
  val left : ('sub, 'super) contains -> ('sub, 'super * 'added) contains
  (** If a scope is contained in the existing side, it is contained after a join. *)
  val right : ('added, 'existing * 'added) contains
  (** The newly joined table is contained on the right side of a join. *)
  val column :
    ('sub, 'super) contains -> ('sub, 'a) column -> ('super, 'a) column
  (** Promote a column only when containment evidence proves it is visible. *)
end

module Source : sig
  type 'scope t
  (** A FROM source with the phantom scope of all visible tables. *)

  val from : 'table table -> 'table t
  (** Start a source from one table. *)
  val join :
    ?op:[ `Inner | `Left ] ->
    on:('existing * 'added, bool) Expr.t ->
    'added table ->
    'existing t ->
    ('existing * 'added) t
  (** Join one table onto an existing source. [on] is checked against the
      enlarged scope and can reference both existing columns and the new table. *)
end

module Select : sig
  type ('scope, 'a) t

  val from : 'table table -> ('table, 'a) Projection.t -> ('table, 'a) t
  val from_source : 'scope Source.t -> ('scope, 'a) Projection.t -> ('scope, 'a) t
  val with_cte :
    name:string -> _ Compiled.select -> ('scope, 'a) t -> ('scope, 'a) t
  val distinct : ('scope, 'a) t -> ('scope, 'a) t
  val where : ('scope, bool) Expr.t -> ('scope, 'a) t -> ('scope, 'a) t
  val group_by : ('scope, 'b) column -> ('scope, 'a) t -> ('scope, 'a) t
  val group_by_many :
    ('scope, 'b) column list -> ('scope, 'a) t -> ('scope, 'a) t
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
  val on_conflict_do_nothing :
    ('table, 'a) column list -> 'table t -> 'table t
  val on_conflict_update :
    ('table, 'a) column list ->
    set:('table, 'b) column list ->
    'table t ->
    'table t
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

  val references :
    ?on_delete:string -> ?on_update:string -> (_, _) column -> reference
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

module Eta_pool : sig
  type error = [ `Eta_sql of sql_error | `Pool_shutdown | `Pool_shutdown_timeout | `Timeout ]
  type pool
  type tx
  type 'kind runner
  type t = pool runner

  val create :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    ?default_timeout:Eta.Duration.t ->
    ?name:string ->
    ?max_size:int ->
    ?max_idle:int ->
    ?idle_lifetime:Eta.Duration.t ->
    ?max_lifetime:Eta.Duration.t ->
    Sqlite.config ->
    (t, error) Eta.Effect.t
  (** Create a SQLite runner pool. [blocking_pool] and [default_timeout] are
      pool defaults used by every operation unless that operation overrides the
      timeout. *)

  val query :
    ?timeout:Eta.Duration.t ->
    'kind runner ->
    string ->
    Value.t list ->
    (Row.t list, error) Eta.Effect.t
  (** Run raw SQL with dynamic values on either a pool or transaction runner. *)

  val select :
    ?timeout:Eta.Duration.t ->
    'kind runner ->
    'a Compiled.select ->
    ('a list, error) Eta.Effect.t
  (** Run a compiled typed SELECT on either a pool or transaction runner. *)

  val returning :
    ?timeout:Eta.Duration.t ->
    'kind runner ->
    'a Compiled.returning ->
    ('a list, error) Eta.Effect.t
  (** Run a compiled INSERT/UPDATE/DELETE RETURNING statement. *)

  val fold :
    ?timeout:Eta.Duration.t ->
    ?batch_size:int ->
    'kind runner ->
    string ->
    Value.t list ->
    init:'a ->
    f:('a -> Row.t -> 'a) ->
    ('a, error) Eta.Effect.t
  (** Fold raw-query rows in bounded SQLite stepping batches. *)

  val fold_select :
    ?timeout:Eta.Duration.t ->
    ?batch_size:int ->
    'kind runner ->
    'row Compiled.select ->
    init:'a ->
    f:('a -> 'row -> 'a) ->
    ('a, error) Eta.Effect.t
  (** Fold typed SELECT rows in bounded SQLite stepping batches. *)

  val execute :
    ?timeout:Eta.Duration.t ->
    'kind runner ->
    string ->
    Value.t list ->
    (int, error) Eta.Effect.t
  (** Execute raw SQL and return SQLite's changed-row count. *)

  val execute_compiled :
    ?timeout:Eta.Duration.t ->
    'kind runner ->
    Compiled.change ->
    (int, error) Eta.Effect.t
  (** Execute a compiled INSERT, UPDATE, or DELETE. *)

  val execute_script :
    ?timeout:Eta.Duration.t ->
    'kind runner ->
    string ->
    (unit, error) Eta.Effect.t
  (** Execute a SQLite script. *)

  val run_schema :
    ?timeout:Eta.Duration.t ->
    'kind runner ->
    Compiled.schema ->
    (unit, error) Eta.Effect.t
  (** Execute a compiled schema statement. *)

  val with_transaction :
    ?timeout:Eta.Duration.t ->
    t ->
    (tx runner -> ('a, error) Eta.Effect.t) ->
    ('a, error) Eta.Effect.t
  (** Run [body] with a transaction runner, committing on success and rolling
      back on failure or cancellation. *)

  val shutdown : ?deadline:Eta.Duration.t -> t -> (unit, error) Eta.Effect.t
  (** Shut down the runner pool. *)

  val stats : t -> Eta.Pool.stats
  (** Snapshot pool counters. *)
end

module Migrate : sig
  module Version : sig
    type t

    type error =
      | Not_positive of int64
      | Invalid_integer of string
      | Expected_integer_value

    val from_int : int -> (t, error) result
    val from_int64 : int64 -> (t, error) result
    val from_string : string -> (t, error) result
    val from_int64_unchecked : int64 -> t
    val to_int64 : t -> int64
    val to_string : t -> string
    val equal : t -> t -> bool
    val compare : t -> t -> int
    val error_to_string : error -> string
  end

  module Table_name : sig
    type t

    type error =
      | Empty
      | Invalid_identifier of string

    val default : t
    val from_string : string -> (t, error) result
    val from_string_unchecked : string -> t
    val to_string : t -> string
    val error_to_string : error -> string
  end

  type migration_type =
    | Simple
    | Reversible_up
    | Reversible_down

  val migration_type_to_string : migration_type -> string

  module Migration : sig
    type t = private {
      version : Version.t;
      description : string;
      migration_type : migration_type;
      sql : string;
      checksum : string;
      no_tx : bool;
    }

    val make :
      ?no_tx:bool ->
      ?checksum:string ->
      version:Version.t ->
      description:string ->
      migration_type:migration_type ->
      sql:string ->
      unit ->
      t
  end

  module Applied_migration : sig
    type t = {
      version : Version.t;
      checksum : string;
    }
  end

  module Config : sig
    type t = {
      table_name : Table_name.t;
      ignore_missing : bool;
    }

    val default : t
  end

  type applied = {
    migration : Migration.t;
    elapsed_ms : int;
  }

  type run_report = {
    applied : applied list;
    already_applied : Applied_migration.t list;
  }

  type source_error =
    | Read_migration_file_failed of {
        path : string;
        reason : string;
      }
    | Read_migration_directory_failed of {
        path : string;
        reason : string;
      }
    | Inspect_migration_path_failed of {
        path : string;
        reason : string;
      }

  type error =
    | Source_error of source_error
    | Invalid_version of Version.error
    | Invalid_table_name of Table_name.error
    | Sql_error of sql_error
    | Dirty of Version.t
    | Version_missing of Version.t
    | Version_mismatch of Version.t
    | Version_not_present of Version.t
    | Migration_execution_error of {
        version : Version.t;
        error : sql_error;
      }

  module Source : sig
    type resolve_config = {
      ignored_checksum_chars : char list;
    }

    val default_resolve_config : resolve_config

    type t

    val from_directory : string -> t
    val from_migrations : Migration.t list -> t
    val resolve : ?config:resolve_config -> t -> (Migration.t list, error) result
  end

  val error_to_string : error -> string
  val list_applied :
    ?config:Config.t ->
    Eta_pool.t ->
    (Applied_migration.t list, error) Eta.Effect.t
  val run :
    ?config:Config.t ->
    Eta_pool.t ->
    Source.t ->
    (run_report, error) Eta.Effect.t
  val run_to :
    ?config:Config.t ->
    Eta_pool.t ->
    Source.t ->
    target:Version.t ->
    (run_report, error) Eta.Effect.t
  val undo :
    ?config:Config.t ->
    Eta_pool.t ->
    Source.t ->
    target:Version.t ->
    (run_report, error) Eta.Effect.t
end
