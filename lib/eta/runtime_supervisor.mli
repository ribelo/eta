type ('s, !'err) supervisor
type ('s, !'err, !'a) child

val make :
  sw:Runtime_contract.scope -> max_failures:int option -> ('s, 'err) supervisor

val scope : ('s, 'err) supervisor -> Runtime_contract.scope
val max_failures : ('s, 'err) supervisor -> int option
val record_failure : ('s, 'err) supervisor -> 'err Cause.t -> unit
val failures : ('s, 'err) supervisor -> 'err Cause.t list
val failure_count : ('s, 'err) supervisor -> int
val register_child : ('s, 'err) supervisor -> (unit -> unit) -> int
val unregister_child : ('s, 'err) supervisor -> int -> unit
val cancel_children : ('s, 'err) supervisor -> unit

val make_child :
  promise:('a, 'err Cause.t) result Runtime_contract.promise ->
  cancel:(unit -> unit) ->
  ('s, 'err, 'a) child

val child_promise :
  ('s, 'err, 'a) child -> ('a, 'err Cause.t) result Runtime_contract.promise

val[@zero_alloc arity 1] child_cancel : ('s, 'err, 'a) child -> unit -> unit
