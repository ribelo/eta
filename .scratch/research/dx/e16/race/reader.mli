open Eta

(** An optional Reader transformer for explicit application dependencies.

    A Reader value describes an Eta effect that still needs an immutable
    application environment. Runtime-owned services such as Eta's clock,
    logger, tracer, and random source do not belong in this environment. *)

type ('env, 'a, 'err) t = 'env -> ('a, 'err) Effect.t

(** Supply the application environment and obtain the underlying Eta effect. *)
val run : 'env -> ('env, 'a, 'err) t -> ('a, 'err) Effect.t

(** Return the current application environment. *)
val ask : ('env, 'env, 'err) t

(** Run one lexical subtree against a transformed environment. [local] does not
    mutate the outer environment; code outside the subtree sees the original. *)
val local :
  ('env -> 'env) -> ('env, 'a, 'err) t -> ('env, 'a, 'err) t

(** Lift a pure value. *)
val pure : 'a -> ('env, 'a, 'err) t

(** Lift an Eta effect that does not inspect the application environment. *)
val lift : ('a, 'err) Effect.t -> ('env, 'a, 'err) t

(** Transform a successful result. *)
val map :
  ('a -> 'b) -> ('env, 'a, 'err) t -> ('env, 'b, 'err) t

(** Sequence Readers while sharing the same application environment. *)
val bind :
  ('a -> ('env, 'b, 'err) t) ->
  ('env, 'a, 'err) t ->
  ('env, 'b, 'err) t

module Syntax : sig
  val ( let* ) :
    ('env, 'a, 'err) t ->
    ('a -> ('env, 'b, 'err) t) ->
    ('env, 'b, 'err) t

  val ( let+ ) :
    ('env, 'a, 'err) t -> ('a -> 'b) -> ('env, 'b, 'err) t
end
