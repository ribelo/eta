(** Cached effectful resources.

    A resource owns a loader effect and the last successfully loaded
    value. Refreshing only updates the cache after the loader succeeds. *)

type ('env, 'err, 'a) t

val manual :
  ('env, 'err, 'a) Effect.t ->
  ('env, 'err, ('env, 'err, 'a) t) Effect.t

val get : ('env, 'err, 'a) t -> ('env, 'err, 'a) Effect.t
val refresh : ('env, 'err, 'a) t -> ('env, 'err, unit) Effect.t
