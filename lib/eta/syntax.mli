(** Binding operators for {!Effect.t}. *)

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
(** Run two effects concurrently and bind both successful values. *)

val ( and+ ) :
  ('a, 'err) Effect.t -> ('b, 'err) Effect.t -> ('a * 'b, 'err) Effect.t
(** Run two effects concurrently and map both successful values. *)
