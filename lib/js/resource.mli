(** Cached effectful resources for eta_js. *)

type ('a, 'err) t

val manual : ('a, 'err) Effect.t -> (('a, 'err) t, 'err) Effect.t

val auto :
  ?on_error:('err -> unit) ->
  load:('a, 'err) Effect.t ->
  ?random:Capabilities.random ->
  schedule:Schedule.t ->
  unit ->
  (('a, 'err) t, 'err) Effect.t

val get : ('a, 'err) t -> ('a, 'err) Effect.t
val refresh : ('a, 'err) t -> (unit, 'err) Effect.t
val failures : ('a, 'err) t -> ('err Cause.t list, 'outer_err) Effect.t
