(** Binding operators for {!Effect.t}.

    Prefer opening this module locally at Eta workflow boundaries, for example
    [let open Eta.Syntax in ...], instead of spelling primitive
    {!Effect.bind} in user code.

    Concurrent and sequential product operators live in submodules:
    - {!Parallel} — fork both sides; fail-fast cancels the sibling
    - {!Applicative} — strict left-to-right; nothing is forked

    Open exactly one of {!Parallel} or {!Applicative} with {!Syntax}. Opening
    both shadows [and*]/[and+] so only the last open's semantics remain —
    that is almost always a mistake. *)

val ( let* ) :
  ('a, 'err) Effect.t ->
  ('a -> ('b, 'err) Effect.t) ->
  ('b, 'err) Effect.t

val ( let+ ) : ('a, 'err) Effect.t -> ('a -> 'b) -> ('b, 'err) Effect.t

val ( let@ ) : (('a -> 'b) -> 'c) -> ('a -> 'b) -> 'c
(** Callback inversion for CPS [with_*] functions.

    [let@ x = with_thing args in body] is [with_thing args (fun x -> body)].
    It is intentionally not Eta-eff-specific and does not add RAII or
    cleanup behavior; lifecycle safety remains owned by the [with_*] function
    being called. *)

(** Concurrent product: both sides fork; first failure cancels the sibling.

    Open with {!Syntax} when independent effects should run together.
    Do not open together with {!Applicative} — the later open shadows. *)
module Parallel : sig
  val ( and* ) :
    ('a, 'err) Effect.t -> ('b, 'err) Effect.t -> ('a * 'b, 'err) Effect.t
  (** Concurrent product via {!Effect.par}.

      Both sides start as sibling fibers. First failure cancels the other
      sibling and propagates that cause. Pair order is [(left, right)]. *)

  val ( and+ ) :
    ('a, 'err) Effect.t -> ('b, 'err) Effect.t -> ('a * 'b, 'err) Effect.t
  (** Same concurrent product as {!val-and*}; used under [let+]. *)
end

(** Sequential product: left settles fully, then right runs; nothing is forked.

    Open with {!Syntax} when product binding must preserve left-to-right
    effect order. Do not open together with {!Parallel} — the later open
    shadows. *)
module Applicative : sig
  val ( and* ) :
    ('a, 'err) Effect.t -> ('b, 'err) Effect.t -> ('a * 'b, 'err) Effect.t
  (** Sequential product: [let* a = left in let+ b = right in (a, b)].

      Left runs to settlement first; right starts only after left succeeds.
      Nothing is forked. Left failure skips right (fail-fast by sequencing). *)

  val ( and+ ) :
    ('a, 'err) Effect.t -> ('b, 'err) Effect.t -> ('a * 'b, 'err) Effect.t
  (** Same sequential product as {!val-and*}; used under [let+]. *)
end
