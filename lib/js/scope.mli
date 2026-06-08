type t
type child

val create : unit -> t
val is_closed : t -> bool
val child_count : t -> int
val register_child :
  t -> id:int -> cancel:(Obj.t Cause.t -> unit) -> child
val child_done : t -> child -> unit
val close :
  t ->
  scheduler:Scheduler.t ->
  ?cause:Obj.t Cause.t ->
  (unit -> unit) ->
  unit
