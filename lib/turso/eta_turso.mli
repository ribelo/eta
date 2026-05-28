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

  val execute :
    ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
    t ->
    string ->
    Value.t list ->
    (int, error) Eta.Effect.t

  val shutdown : ?deadline:Eta.Duration.t -> t -> (unit, error) Eta.Effect.t
  val stats : t -> Eta.Pool.stats
end
