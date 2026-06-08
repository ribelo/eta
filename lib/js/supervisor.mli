(** Scope-bound supervised concurrency. *)

type ('s, 'err) t = ('s, 'err) Effect.supervisor
type ('s, 'err) supervisor = ('s, 'err) t
type ('s, 'err, 'a) child = ('s, 'err, 'a) Effect.supervisor_child

module Scope : sig
  type ('s, 'a, 'err) t = ('s, 'a, 'err) Effect.supervisor_scope

  val pure : 'a -> ('s, 'a, 'err) t
  val lift : ('a, 'err) Effect.t -> ('s, 'a, 'err) t
  val fail : 'err -> ('s, 'a, 'err) t

  val bind :
    ('a -> ('s, 'b, 'err) t) ->
    ('s, 'a, 'err) t ->
    ('s, 'b, 'err) t

  val ( let* ) :
    ('s, 'a, 'err) t ->
    ('a -> ('s, 'b, 'err) t) ->
    ('s, 'b, 'err) t

  val start :
    ('s, 'err) supervisor ->
    ('s, 'a, 'err) t ->
    ('s, ('s, 'err, 'a) child, 'outer_err) t

  val await : ('s, 'err, 'a) child -> ('s, 'a, 'err) t
  val cancel : ('s, 'err, 'a) child -> ('s, unit, 'err) t
  val failures : ('s, 'err) supervisor -> ('s, 'err Cause.t list, 'outer_err) t

  val check :
    ('s, [> `Supervisor_failed of int ] as 'err) supervisor ->
    ('s, unit, 'err) t

  val yield : ('s, unit, 'err) t
end

type ('a, 'err) body = {
  run : 's. ('s, 'err) t -> ('s, 'a, 'err) Scope.t;
}

val scoped : ?max_failures:int -> ('a, 'err) body -> ('a, 'err) Effect.t
