type fiber_status =
  | Ready
  | Running
  | Waiting
  | Done

type packed_exit = Exit : ('a, 'err) Exit.t -> packed_exit

type t

val create_root : scheduler:Scheduler.t -> t
val create_child : t -> t
val id : t -> int
val scheduler : t -> Scheduler.t
val scope : t -> Scope.t
val status : t -> fiber_status
val set_status : t -> fiber_status -> unit
val child_count : t -> int
val cancel_cause : t -> Obj.t Cause.t option
val exit : t -> packed_exit option
val observe : t -> (packed_exit -> unit) -> unit
val finish : t -> packed_exit -> unit
val cancel : t -> Obj.t Cause.t -> unit
val interruptible : t -> bool
val set_interruptible : t -> bool -> unit
val set_cancel_waiter : t -> (unit -> unit) option -> unit
val local_get : t -> 'a Runtime_local.key -> 'a option
val local_set : t -> 'a Runtime_local.key -> 'a -> unit
val local_with_binding : t -> 'a Runtime_local.key -> 'a -> (unit -> 'b) -> 'b
