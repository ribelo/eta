(** Eta-native SQLite runner API.

    The typed DSL is a construction aid, not a closed enforcement boundary for
    this module. [Raw] operations are deliberate escape hatches; callers using
    them own SQL validity, parameter ordering, and result decoding. Prefer
    [Typed.select], [Typed.fold_select],
    [Typed.execute_compiled], [Typed.returning], and [Typed.run_schema] when
    table, column, and projection typing should apply. *)

type error = [ `Eta_sql of Types.sql_error | `Pool_shutdown | `Pool_shutdown_timeout | `Timeout ]
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

module Typed : sig
  val select :
    ?timeout:Eta.Duration.t ->
    'kind runner ->
    'a Dsl.Compiled.select ->
    ('a list, error) Eta.Effect.t
  (** Run a compiled typed SELECT on either a pool or transaction runner. *)

  val returning :
    ?timeout:Eta.Duration.t ->
    'kind runner ->
    'a Dsl.Compiled.returning ->
    ('a list, error) Eta.Effect.t
  (** Run a compiled INSERT/UPDATE/DELETE RETURNING statement. *)

  val fold_select :
    ?timeout:Eta.Duration.t ->
    ?batch_size:int ->
    'kind runner ->
    'row Dsl.Compiled.select ->
    init:'a ->
    f:('a -> 'row -> 'a) ->
    ('a, error) Eta.Effect.t
  (** Fold typed SELECT rows in bounded SQLite stepping batches. *)

  val execute_compiled :
    ?timeout:Eta.Duration.t ->
    'kind runner ->
    Dsl.Compiled.change ->
    (int, error) Eta.Effect.t
  (** Execute a compiled INSERT, UPDATE, or DELETE. *)

  val run_schema :
    ?timeout:Eta.Duration.t ->
    'kind runner ->
    Dsl.Compiled.schema ->
    (unit, error) Eta.Effect.t
  (** Execute a compiled schema statement. *)
end

module Raw : sig
  val query :
    ?timeout:Eta.Duration.t ->
    'kind runner ->
    string ->
    Value.t list ->
    (Row.t list, error) Eta.Effect.t
  (** Run raw SQL with dynamic values on either a pool or transaction runner.
      This bypasses the typed DSL. *)

  val fold :
    ?timeout:Eta.Duration.t ->
    ?batch_size:int ->
    'kind runner ->
    string ->
    Value.t list ->
    init:'a ->
    f:('a -> Row.t -> 'a) ->
    ('a, error) Eta.Effect.t
  (** Fold raw-query rows in bounded SQLite stepping batches. This bypasses the
      typed DSL. *)

  val execute :
    ?timeout:Eta.Duration.t ->
    'kind runner ->
    string ->
    Value.t list ->
    (int, error) Eta.Effect.t
  (** Execute raw SQL and return SQLite's changed-row count. This bypasses the
      typed DSL. *)

  val execute_script :
    ?timeout:Eta.Duration.t ->
    'kind runner ->
    string ->
    (unit, error) Eta.Effect.t
  (** Execute a SQLite script. This bypasses the typed DSL. *)

  val with_connection :
    'kind runner ->
    (Connection.t -> ('a, error) Eta.Effect.t) ->
    ('a, error) Eta.Effect.t
  (** Run an operation against the checked-out SQLite connection behind a
      runner. This is the lowest-level escape hatch and bypasses the typed DSL. *)
end

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
