type child_registration
type ('s, !'err) supervisor
type ('s, !'err, !'a) child

val make : max_failures:int option -> ('s, 'err) supervisor
val max_failures : ('s, 'err) supervisor -> int option
val record_failure : ('s, 'err) supervisor -> 'err Cause.t -> unit
val failures : ('s, 'err) supervisor -> 'err Cause.t list
val failure_count : ('s, 'err) supervisor -> int

val register_child :
  ('s, 'err) supervisor ->
  cancel:(unit -> unit) ->
  settled:unit Runtime_promise.t ->
  int

val unregister_child : ('s, 'err) supervisor -> int -> unit
val live_children : ('s, 'err) supervisor -> child_registration list
val cancel_registration : child_registration -> unit
val registration_settled : child_registration -> unit Runtime_promise.t

val make_child :
  promise:('a, 'err Cause.t) result Runtime_promise.t ->
  cancel:(unit -> unit) ->
  ('s, 'err, 'a) child

val child_promise :
  ('s, 'err, 'a) child -> ('a, 'err Cause.t) result Runtime_promise.t

val child_cancel : ('s, 'err, 'a) child -> unit -> unit
