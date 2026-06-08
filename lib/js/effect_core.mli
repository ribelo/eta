type context = {
  scheduler : Scheduler.t;
  fiber : Runtime_fiber.t;
  clock : Runtime_core.clock;
  daemon_started : unit -> unit;
  daemon_finished : unit -> unit;
  daemon_failed : Obj.t Cause.t -> unit;
}

type ('a, +'err) t

val pure : 'a -> ('a, 'err) t
val fail : 'err -> ('a, 'err) t
val sync : (unit -> 'a) -> ('a, 'err) t
val yield_now : (unit, 'err) t
val check : (unit, 'err) t
val map : ('a -> 'b) -> ('a, 'err) t -> ('b, 'err) t
val bind : ('a -> ('b, 'err) t) -> ('a, 'err) t -> ('b, 'err) t
val catch : ('err -> ('a, 'err2) t) -> ('a, 'err) t -> ('a, 'err2) t
val map_error : ('err -> 'err2) -> ('a, 'err) t -> ('a, 'err2) t
val finally : (unit, 'cleanup_err) t -> ('a, 'err) t -> ('a, 'err) t
val uninterruptible : ('a, 'err) t -> ('a, 'err) t

val async_leaf :
  ?name:string ->
  (context ->
   resume:(('a, 'err) Exit.t -> unit) ->
   on_cancel:((unit -> unit) -> unit) ->
   unit) ->
  ('a, 'err) t

val run_promise : context -> ('a, 'err) t -> ('a, 'err) Exit.t Js.Promise.t
val run_now : context -> ('a, 'err) t -> ('a, 'err) Exit.t option
