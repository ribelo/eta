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
end

module Column : sig
  type ('table, 'a) t = ('table, 'a) column

  val name : (_, _) t -> string
  val table_name : (_, _) t -> string
end

module Expr : sig
  type 'scope t

  val true_ : 'scope t
  val false_ : 'scope t
  val eq : ('scope, 'a) column -> 'a -> 'scope t
  val ne : ('scope, 'a) column -> 'a -> 'scope t
  val gt : ('scope, 'a) column -> 'a -> 'scope t
  val ge : ('scope, 'a) column -> 'a -> 'scope t
  val lt : ('scope, 'a) column -> 'a -> 'scope t
  val le : ('scope, 'a) column -> 'a -> 'scope t
  val like : ('scope, string) column -> string -> 'scope t
  val eq_col : ('scope, 'a) column -> ('scope, 'a) column -> 'scope t
  val is_null : ('scope, 'a option) column -> 'scope t
  val is_not_null : ('scope, 'a option) column -> 'scope t
  val in_select : ('scope, 'a) column -> 'a Compiled.select -> 'scope t
  val exists : _ Compiled.select -> 'scope t
  val count_eq : int -> 'scope t
  val count_gt : int -> 'scope t
  val count_ge : int -> 'scope t
  val and_ : 'scope t -> 'scope t -> 'scope t
  val or_ : 'scope t -> 'scope t -> 'scope t
  val not_ : 'scope t -> 'scope t
end

module Projection : sig
  type ('scope, 'a) t

  val one : ('scope, 'a) column -> ('scope, 'a) t
  val t2 : ('scope, 'a) column -> ('scope, 'b) column -> ('scope, 'a * 'b) t
  val t3 :
    ('scope, 'a) column ->
    ('scope, 'b) column ->
    ('scope, 'c) column ->
    ('scope, 'a * 'b * 'c) t
  val count : ?as_:string -> unit -> ('scope, int) t
  val sum_int : ?as_:string -> ('scope, int) column -> ('scope, int) t
  val row_number :
    ?as_:string ->
    ?partition_by:('scope, 'a) column list ->
    ?order_by:('scope, 'b) column ->
    unit ->
    ('scope, int) t
  val t4 :
    ('scope, 'a) column ->
    ('scope, 'b) column ->
    ('scope, 'c) column ->
    ('scope, 'd) column ->
    ('scope, 'a * 'b * 'c * 'd) t
  val t5 :
    ('scope, 'a) column ->
    ('scope, 'b) column ->
    ('scope, 'c) column ->
    ('scope, 'd) column ->
    ('scope, 'e) column ->
    ('scope, 'a * 'b * 'c * 'd * 'e) t
  val t6 :
    ('scope, 'a) column ->
    ('scope, 'b) column ->
    ('scope, 'c) column ->
    ('scope, 'd) column ->
    ('scope, 'e) column ->
    ('scope, 'f) column ->
    ('scope, 'a * 'b * 'c * 'd * 'e * 'f) t
  val t7 :
    ('scope, 'a) column ->
    ('scope, 'b) column ->
    ('scope, 'c) column ->
    ('scope, 'd) column ->
    ('scope, 'e) column ->
    ('scope, 'f) column ->
    ('scope, 'g) column ->
    ('scope, 'a * 'b * 'c * 'd * 'e * 'f * 'g) t
  val t8 :
    ('scope, 'a) column ->
    ('scope, 'b) column ->
    ('scope, 'c) column ->
    ('scope, 'd) column ->
    ('scope, 'e) column ->
    ('scope, 'f) column ->
    ('scope, 'g) column ->
    ('scope, 'h) column ->
    ('scope, 'a * 'b * 'c * 'd * 'e * 'f * 'g * 'h) t
  val map : ('a -> 'b) -> ('scope, 'a) t -> ('scope, 'b) t
end

module Join : sig
  val left : ('left, 'a) column -> ('left * 'right, 'a) column
  val right : ('right, 'a) column -> ('left * 'right, 'a) column
  val on_eq : ('left, 'a) column -> ('right, 'a) column -> ('left * 'right) Expr.t
end

module Source : sig
  type 'scope t

  val table : 'table table -> 'table t
  val inner_join :
    'left table -> 'right table -> on:('left * 'right) Expr.t -> ('left * 'right) t
  val left_join :
    'left table -> 'right table -> on:('left * 'right) Expr.t -> ('left * 'right) t
end

module Select : sig
  type ('scope, 'a) t

  val from : 'table table -> ('table, 'a) Projection.t -> ('table, 'a) t
  val from_source : 'scope Source.t -> ('scope, 'a) Projection.t -> ('scope, 'a) t
  val with_cte :
    name:string -> _ Compiled.select -> ('scope, 'a) t -> ('scope, 'a) t
  val distinct : ('scope, 'a) t -> ('scope, 'a) t
  val where : 'scope Expr.t -> ('scope, 'a) t -> ('scope, 'a) t
  val group_by : ('scope, 'b) column -> ('scope, 'a) t -> ('scope, 'a) t
  val group_by_many :
    ('scope, 'b) column list -> ('scope, 'a) t -> ('scope, 'a) t
  val having : 'scope Expr.t -> ('scope, 'a) t -> ('scope, 'a) t
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
  val where : 'table Expr.t -> 'table t -> 'table t
  val to_sql : _ t -> string
  val compile : _ t -> Compiled.change
  val returning : ('table, 'a) Projection.t -> 'table t -> 'a Compiled.returning
end

module Delete : sig
  type 'table t

  val from : 'table table -> 'table t
  val where : 'table Expr.t -> 'table t -> 'table t
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

module Connection : sig
  type t

  val create : Sqlite.config -> (t, error) result
  val sqlite : t -> Sqlite.db
  val query : t -> string -> Value.t list -> (Row.t list, error) result
  val select : t -> 'a Compiled.select -> ('a list, error) result
  val returning : t -> 'a Compiled.returning -> ('a list, error) result
  val execute : t -> string -> Value.t list -> (int, error) result
  val execute_compiled : t -> Compiled.change -> (int, error) result
  val execute_script : t -> string -> (unit, error) result
  val run_schema : t -> Compiled.schema -> (unit, error) result
  val prepare_migration : t -> string -> (string list, error) result
  val ping : t -> bool
  val close : t -> unit
  val begin_transaction : t -> (unit, error) result
  val commit : t -> (unit, error) result
  val rollback : t -> (unit, error) result
  val with_transaction : t -> (t -> ('a, error) result) -> ('a, error) result
  val id : t -> string
  val created_at : t -> float
  val last_used : t -> float
  val pool_lease : t -> int
  val set_pool_lease : t -> int -> unit
end

module Transaction : sig
  type t

  val begin_transaction : Connection.t -> (t, error) result
  val commit : t -> (unit, error) result
  val rollback : t -> (unit, error) result
  val with_transaction : Connection.t -> (Connection.t -> ('a, error) result) -> ('a, error) result
end

module Pool : sig
  type clock

  type config = {
    sqlite : Sqlite.config;
    min_connections : int;
    max_connections : int;
    acquire_timeout_ms : int option;
    idle_timeout_ms : int option;
    max_lifetime_ms : int option;
  }

  type t

  type stat =
    | Total_connections of int
    | Available_connections of int
    | In_use_connections of int
    | Waiting_requests of int

  val config :
    ?min_connections:int ->
    ?max_connections:int ->
    ?acquire_timeout_ms:int ->
    ?idle_timeout_ms:int ->
    ?max_lifetime_ms:int ->
    Sqlite.config ->
    config
  val create : ?clock:_ Eio.Time.clock -> config -> (t, error) result
  val acquire : t -> (Connection.t, error) result
  val release : t -> Connection.t -> unit
  val with_connection : t -> (Connection.t -> ('a, error) result) -> ('a, error) result
  val shutdown : t -> unit
  val stats : t -> stat list
end

module Eta_pool : sig
  type error = [ `Eta_sql of sql_error | `Pool_shutdown | `Pool_shutdown_timeout | `Timeout ]
  type t
  type tx

  val create :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    ?name:string ->
    ?max_size:int ->
    ?max_idle:int ->
    ?idle_lifetime:Eta.Duration.t ->
    ?max_lifetime:Eta.Duration.t ->
    Sqlite.config ->
    (t, error) Eta.Effect.t

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

  val fold :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    ?batch_size:int ->
    t ->
    string ->
    Value.t list ->
    init:'a ->
    f:('a -> Row.t -> 'a) ->
    ('a, error) Eta.Effect.t

  val fold_select :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    ?batch_size:int ->
    t ->
    'row Compiled.select ->
    init:'a ->
    f:('a -> 'row -> 'a) ->
    ('a, error) Eta.Effect.t

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

  val execute_script :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    t ->
    string ->
    (unit, error) Eta.Effect.t

  val run_schema :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    t ->
    Compiled.schema ->
    (unit, error) Eta.Effect.t

  val tx_select :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    tx ->
    'a Compiled.select ->
    ('a list, error) Eta.Effect.t

  val tx_fold_select :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    ?batch_size:int ->
    tx ->
    'row Compiled.select ->
    init:'a ->
    f:('a -> 'row -> 'a) ->
    ('a, error) Eta.Effect.t

  val tx_returning :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    tx ->
    'a Compiled.returning ->
    ('a list, error) Eta.Effect.t

  val tx_execute_compiled :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    tx ->
    Compiled.change ->
    (int, error) Eta.Effect.t

  val tx_run_schema :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    tx ->
    Compiled.schema ->
    (unit, error) Eta.Effect.t

  val with_transaction :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    timeout:Eta.Duration.t ->
    t ->
    (tx -> ('a, error) Eta.Effect.t) ->
    ('a, error) Eta.Effect.t

  val shutdown : ?deadline:Eta.Duration.t -> t -> (unit, error) Eta.Effect.t
  val stats : t -> Eta.Pool.stats
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
    ?config:Config.t -> Pool.t -> (Applied_migration.t list, error) result
  val run : ?config:Config.t -> Pool.t -> Source.t -> (run_report, error) result
  val run_to :
    ?config:Config.t ->
    Pool.t ->
    Source.t ->
    target:Version.t ->
    (run_report, error) result
  val undo :
    ?config:Config.t ->
    Pool.t ->
    Source.t ->
    target:Version.t ->
    (run_report, error) result
end

val connect :
  ?clock:_ Eio.Time.clock ->
  ?min_connections:int ->
  ?max_connections:int ->
  Sqlite.config ->
  (Pool.t, error) result
val query : Pool.t -> string -> Value.t list -> (Row.t list, error) result
val exec : Pool.t -> string -> Value.t list -> (int, error) result
val with_transaction : Pool.t -> (Connection.t -> ('a, error) result) -> ('a, error) result
val migrate :
  ?config:Migrate.Config.t ->
  ?source:Migrate.Source.t ->
  Pool.t ->
  unit ->
  (unit, Migrate.error) result
val shutdown : Pool.t -> unit
