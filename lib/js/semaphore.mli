(** Cancellation-safe counting semaphore for eta_js fibers. *)

type t

val make : permits:int -> t
val try_acquire : t -> int -> bool
val acquire : t -> int -> (unit, 'err) Effect.t
val release : t -> int -> unit
val with_permits : t -> int -> (unit -> ('a, 'err) Effect.t) -> ('a, 'err) Effect.t

val with_permits_or_abort :
  t ->
  int ->
  abort:('abort, 'err) Effect.t ->
  (unit -> ('a, 'err) Effect.t) ->
  ('a option, 'err) Effect.t

val available : t -> int
val waiting : t -> int
val cancelled_waiters : t -> int
