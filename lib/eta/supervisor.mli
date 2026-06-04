(** Scope-bound supervised concurrency.

    A supervisor is a lexical nursery: child handles exist only inside
    [scoped]. The rank-2 body prevents a child from escaping its owning
    supervisor scope.

    Ordering note: this module documents the same-domain supervisor contract.
    Same-domain failures are returned in observation order, which follows the
    order in which this runtime records completed child failures. The H3
    portable supervisor path uses a different contract: each child is assigned
    a stable task index, and portable failure snapshots are reassembled in
    task-index order. Do not infer portable supervisor ordering from the
    same-domain observation order below. *)

type ('s, 'err) t = ('s, 'err) Effect.supervisor
type ('s, 'err) supervisor = ('s, 'err) t
type ('s, 'err, 'a) child = ('s, 'err, 'a) Effect.supervisor_child

module Scope : sig
  type ('s, 'a, 'err) t = ('s, 'a, 'err) Effect.supervisor_scope

  val pure : 'a -> ('s, 'a, 'err) t
  val lift : ('a, 'err) Effect.t -> ('s, 'a, 'err) t
  val fail : 'err -> ('s, 'a, 'err) t

  val bind :
    ('a -> ('s, 'b, 'err) t) @ many ->
    ('s, 'a, 'err) t ->
    ('s, 'b, 'err) t

  val ( let* ) :
    ('s, 'a, 'err) t ->
    ('a -> ('s, 'b, 'err) t) @ many ->
    ('s, 'b, 'err) t

  val start :
    ('s, 'err) supervisor ->
    ('s, 'a, 'err) t ->
    ('s, ('s, 'err, 'a) child, 'outer_err) t
  (** Start [child] under [supervisor]. The returned handle cannot be used
      outside the surrounding {!scoped} body. Child failures are recorded on
      the supervisor; they do not fail the parent unless awaited. *)

  val await : ('s, 'err, 'a) child -> ('s, 'a, 'err) t
  (** Wait for a child and re-enter its typed error channel. *)

  val cancel : ('s, 'err, 'a) child -> ('s, unit, 'err) t
  (** Cancel a child and wait for it to settle. Pure interruption is treated as
      successful cancellation; a child failure or finalizer failure is re-raised
      in the scope's typed failure channel. Awaiting the child afterwards
      returns interruption. *)

  val failures :
    ('s, 'err) supervisor -> ('s, 'err Cause.t list, 'outer_err) t
  (** Return observed child failures in same-domain observation order.

      Portable domain supervisors must instead expose task-index order, because
      cross-domain completion observation is intentionally not a user-visible
      ordering source. *)

  val check :
    ('s, [> `Supervisor_failed of int ] as 'err) supervisor ->
    ('s, unit, 'err) t
  (** Fail with [`Supervisor_failed n] once the supervisor has observed at
      least the configured [max_failures] child failures. Supervisors without
      a threshold never fail this check. Same-domain counting follows
      observation order; portable supervisors count failures after task-index
      reassembly. *)

  val yield : ('s, unit, 'err) t
end

type ('a, 'err) body = {
  run : 's. ('s, 'err) t -> ('s, 'a, 'err) Scope.t;
}

val scoped : ?max_failures:int -> ('a, 'err) body -> ('a, 'err) Effect.t
(** Run a supervised nursery. All children are owned by the nursery switch and
    are cancelled when the scope exits. *)
