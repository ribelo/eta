(** Internal SQLite connection API used by [Eta_sql.Pool] and migrations.

    Raw operations in this module bypass the typed SQL DSL. Callers using this
    escape hatch own SQL validity, parameter ordering, and result decoding. *)

type t

val create : Sqlite.config -> (t, Types.sql_error) result
val sqlite : t -> Sqlite.db
val touch : t -> unit
val if_open : t -> (unit -> ('a, Types.sql_error) result) -> ('a, Types.sql_error) result

module Typed : sig
  val select : t -> 'a Dsl.Compiled.select -> ('a list, Types.sql_error) result
  val returning : t -> 'a Dsl.Compiled.returning -> ('a list, Types.sql_error) result
  val execute_compiled : t -> Dsl.Compiled.change -> (int, Types.sql_error) result
  val run_schema : t -> Dsl.Compiled.schema -> (unit, Types.sql_error) result
end

module Raw : sig
  val query : t -> string -> Value.t list -> (Row.t list, Types.sql_error) result
  val execute : t -> string -> Value.t list -> (int, Types.sql_error) result
  val execute_script : t -> string -> (unit, Types.sql_error) result
  val prepare_migration : t -> string -> (string list, Types.sql_error) result
end

val ping : t -> bool
val ensure_autocommit : t -> (unit, Types.sql_error) result
val close : t -> unit

val begin_transaction : t -> (unit, Types.sql_error) result
val commit : t -> (unit, Types.sql_error) result
val rollback : t -> (unit, Types.sql_error) result
val with_transaction : t -> (t -> ('a, Types.sql_error) result) -> ('a, Types.sql_error) result

val id : t -> string
val created_at : t -> float
val last_used : t -> float
val pool_lease : t -> int
val set_pool_lease : t -> int -> unit
