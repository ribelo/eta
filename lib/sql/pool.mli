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
  'a Dsl.Compiled.select ->
  ('a list, error) Eta.Effect.t
(** Run a compiled typed SELECT on either a pool or transaction runner. *)

val returning :
  ?timeout:Eta.Duration.t ->
  'kind runner ->
  'a Dsl.Compiled.returning ->
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
  'row Dsl.Compiled.select ->
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
  Dsl.Compiled.change ->
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
  Dsl.Compiled.schema ->
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

val with_connection :
'kind runner ->
(Connection.t -> ('a, error) Eta.Effect.t) ->
('a, error) Eta.Effect.t
(** Run an operation against the checked-out SQLite connection behind a runner. *)
