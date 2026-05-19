(** Scope-bound supervised concurrency.

    A supervisor is a lexical nursery: child handles exist only inside
    [scoped]. The rank-2 body prevents a child from escaping its owning
    supervisor scope. *)

type ('s, 'err) t = ('s, 'err) Effect.supervisor
type ('s, 'err) supervisor = ('s, 'err) t
type ('s, 'err, 'a) child = ('s, 'err, 'a) Effect.supervisor_child

module Scope : sig
  type ('s, 'env, 'err, 'a) t =
    ('s, 'env, 'err, 'a) Effect.supervisor_scope

  val pure : 'a -> ('s, 'env, 'err, 'a) t
  val lift : ('env, 'err, 'a) Effect.t -> ('s, 'env, 'err, 'a) t
  val fail : 'err -> ('s, 'env, 'err, 'a) t

  val bind :
    ('a -> ('s, 'env, 'err, 'b) t) ->
    ('s, 'env, 'err, 'a) t ->
    ('s, 'env, 'err, 'b) t

  val ( let* ) :
    ('s, 'env, 'err, 'a) t ->
    ('a -> ('s, 'env, 'err, 'b) t) ->
    ('s, 'env, 'err, 'b) t

  val start :
    ('s, 'err) supervisor ->
    ('s, 'env, 'err, 'a) t ->
    ('s, 'env, 'outer_err, ('s, 'err, 'a) child) t
  (** Start [child] under [supervisor]. The returned handle cannot be used
      outside the surrounding {!scoped} body. Child failures are recorded on
      the supervisor; they do not fail the parent unless awaited. *)

  val await : ('s, 'err, 'a) child -> ('s, 'env, 'err, 'a) t
  (** Wait for a child and re-enter its typed error channel. *)

  val cancel : ('s, 'err, 'a) child -> ('s, 'env, 'outer_err, unit) t
  (** Cancel a child. Awaiting the child afterwards returns interruption. *)

  val failures :
    ('s, 'err) supervisor -> ('s, 'env, 'outer_err, 'err Cause.t list) t
  (** Return observed child failures in observation order. *)

  val check :
    ('s, [> `Supervisor_failed of int ] as 'err) supervisor ->
    ('s, 'env, 'err, unit) t
  (** Fail with [`Supervisor_failed n] once the supervisor has observed at
      least the configured [max_failures] child failures. Supervisors without
      a threshold never fail this check. *)

  val yield : ('s, 'env, 'err, unit) t
end

type ('env, 'err, 'a) body = {
  run : 's. ('s, 'err) t -> ('s, 'env, 'err, 'a) Scope.t;
}

val scoped :
  ?max_failures:int ->
  ('env, 'err, 'a) body ->
  ('env, 'err, 'a) Effect.t
(** Run a supervised nursery. All children are owned by the nursery switch and
    are cancelled when the scope exits. *)
