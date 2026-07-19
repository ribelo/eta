(** Binding operators for {!Effect.t}.

    Prefer opening this module locally at Eta workflow boundaries, for example
    [let open Eta.Syntax in ...], instead of spelling primitive
    {!Effect.bind} in user code. *)

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

val ( and* ) :
  ('a, 'err) Effect.t -> ('b, 'err) Effect.t -> ('a * 'b, 'err) Effect.t
(** Strict left-to-right product; nothing is forked.

    Left settles fully, then right runs. Left failure skips right. Rule of
    thumb: [and*] sequences; for concurrency use {!Effect.par}. *)

val ( and+ ) :
  ('a, 'err) Effect.t -> ('b, 'err) Effect.t -> ('a * 'b, 'err) Effect.t
(** Strict left-to-right product under [let+]; nothing is forked.

    Same sequential product as {!val-and*}. Rule of thumb: [and+] sequences;
    for concurrency use {!Effect.par}. *)
