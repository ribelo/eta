(** Cached effectful resources.

    A resource owns a loader effect and the last successfully loaded
    value. Refreshing only updates the cache after the loader succeeds. *)

type ('a, 'err) t

val manual :
  ('a, 'err) Effect.t ->
  (('a, 'err) t, 'err) Effect.t

val auto :
  ?on_error:('err -> unit) ->
  load:('a, 'err) Effect.t ->
  ?random:Capabilities.random ->
  schedule:Schedule.t ->
  unit ->
  (('a, 'err) t, 'err) Effect.t
(** Load once to seed the resource, then refresh it in a runtime-owned
    background fiber according to [schedule]. Refresh failures keep the last
    good value and call [on_error] when provided. *)

val get : ('a, 'err) t -> ('a, 'err) Effect.t
val refresh : ('a, 'err) t -> (unit, 'err) Effect.t
val failures : ('a, 'err) t -> ('err Cause.t list, 'outer_err) Effect.t
(** Return refresh failures observed by this resource in observation order.
    Manual resources start with an empty list. [auto] records typed refresh
    failures as [Cause.Fail err] before invoking [on_error]. *)
