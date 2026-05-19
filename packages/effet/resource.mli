(** Cached effectful resources.

    A resource owns a loader effect and the last successfully loaded
    value. Refreshing only updates the cache after the loader succeeds. *)

type ('env, 'err, 'a) t

val manual :
  ('env, 'err, 'a) Effect.t ->
  ('env, 'err, ('env, 'err, 'a) t) Effect.t

val auto :
  ?on_error:('err -> unit) ->
  load:('env, 'err, 'a) Effect.t ->
  schedule:Schedule.t ->
  unit ->
  ('env, 'err, ('env, 'err, 'a) t) Effect.t
(** Load once to seed the resource, then refresh it in a runtime-owned
    background fiber according to [schedule]. Refresh failures keep the last
    good value and call [on_error] when provided. *)

val get : ('env, 'err, 'a) t -> ('env, 'err, 'a) Effect.t
val refresh : ('env, 'err, 'a) t -> ('env, 'err, unit) Effect.t
