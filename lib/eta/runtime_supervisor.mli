type ('s, !'err) supervisor
type ('s, !'err, !'a) child

val make :
  sw:Eio.Switch.t -> max_failures:int option -> ('s, 'err) supervisor

val fork : ('s, 'err) supervisor -> (unit -> unit) -> unit
val max_failures : ('s, 'err) supervisor -> int option
val record_failure : ('s, 'err) supervisor -> 'err Cause.t -> unit
val failures : ('s, 'err) supervisor -> 'err Cause.t list
val failure_count : ('s, 'err) supervisor -> int
val register_child : ('s, 'err) supervisor -> (unit -> unit) -> int
val unregister_child : ('s, 'err) supervisor -> int -> unit
val cancel_children : ('s, 'err) supervisor -> unit

val make_child :
  promise:('a, 'err Cause.t) result Eio.Promise.t ->
  cancel:(unit -> unit) ->
  ('s, 'err, 'a) child

val child_promise :
  ('s, 'err, 'a) child -> ('a, 'err Cause.t) result Eio.Promise.t

val child_cancel : ('s, 'err, 'a) child -> unit -> unit
