(** Binding operators for {!Effect.t}. *)

val ( let* ) :
  ('a, 'err) Effect.t -> ('a -> ('b, 'err) Effect.t) -> ('b, 'err) Effect.t
(** Monadic bind. *)

val ( let+ ) : ('a, 'err) Effect.t -> ('a -> 'b) -> ('b, 'err) Effect.t
(** Map over a successful value. *)

val ( and* ) :
  ('a, 'err) Effect.t -> ('b, 'err) Effect.t -> ('a * 'b, 'err) Effect.t
(** Run two effects concurrently and bind both successful values. *)

val ( and+ ) :
  ('a, 'err) Effect.t -> ('b, 'err) Effect.t -> ('a * 'b, 'err) Effect.t
(** Run two effects concurrently and map both successful values. *)
