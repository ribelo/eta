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
  | Sql_error of Types.sql_error
  | Dirty of Version.t
  | Version_missing of Version.t
  | Version_mismatch of Version.t
  | Version_not_present of Version.t
  | Migration_execution_error of {
      version : Version.t;
      error : Types.sql_error;
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
  Pool.t ->
  (Applied_migration.t list, error) Eta.Effect.t
val run :
  ?config:Config.t ->
  Pool.t ->
  Source.t ->
  (run_report, error) Eta.Effect.t
val run_to :
  ?config:Config.t ->
  Pool.t ->
  Source.t ->
  target:Version.t ->
  (run_report, error) Eta.Effect.t
val undo :
  ?config:Config.t ->
  Pool.t ->
  Source.t ->
  target:Version.t ->
  (run_report, error) Eta.Effect.t

