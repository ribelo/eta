type ('a, +'err) t = ('a, 'err) Effect_core.t
type ('s, 'err) supervisor
type ('s, 'a, 'err) supervisor_scope
type ('a, 'err) supervisor_body = {
  run : 's. ('s, 'err) supervisor -> ('s, 'a, 'err) supervisor_scope;
}

and ('s, 'err, 'a) supervisor_child

val pure : 'a -> ('a, 'err) t
val fail : 'err -> ('a, 'err) t
val unit : (unit, 'err) t
val from_result : ('a, 'err) result -> ('a, 'err) t
val sync : (unit -> 'a) -> ('a, 'err) t
val yield_now : (unit, 'err) t
val check : (unit, 'err) t
val map : ('a -> 'b) -> ('a, 'err) t -> ('b, 'err) t
val bind : ('a -> ('b, 'err) t) -> ('a, 'err) t -> ('b, 'err) t
val tap : ('a -> (unit, 'err) t) -> ('a, 'err) t -> ('a, 'err) t
val seq : (unit, 'err) t -> ('a, 'err) t -> ('a, 'err) t
val concat : (unit, 'err) t list -> (unit, 'err) t
val race : ('a, 'err) t list -> ('a, 'err) t
val par : ('a, 'err) t -> ('b, 'err) t -> ('a * 'b, 'err) t
val all : ('a, 'err) t list -> ('a list, 'err) t
val all_settled : ('a, 'err) t list -> (('a, 'err Cause.t) result list, 'outer_err) t
val for_each_par : 'x list -> ('x -> ('a, 'err) t) -> ('a list, 'err) t
val for_each_par_bounded :
  max:int -> 'x list -> ('x -> ('a, 'err) t) -> ('a list, 'err) t
val delay : Duration.t -> ('a, 'err) t -> ('a, 'err) t
val timeout_as : Duration.t -> on_timeout:'err -> ('a, 'err) t -> ('a, 'err) t
val timeout : Duration.t -> ('a, [> `Timeout ] as 'err) t -> ('a, 'err) t
val catch : ('err -> ('a, 'err2) t) -> ('a, 'err) t -> ('a, 'err2) t
val catch_cause : ('err Cause.t -> ('a, 'err2) t) -> ('a, 'err) t -> ('a, 'err2) t
val map_error : ('err -> 'err2) -> ('a, 'err) t -> ('a, 'err2) t
val tap_error : ('err -> unit) -> ('a, 'err) t -> ('a, 'err) t
val tap_cause : ('err Cause.t -> unit) -> ('a, 'err) t -> ('a, 'err) t
val finally : (unit, 'cleanup_err) t -> ('a, 'err) t -> ('a, 'err) t
val die : exn -> ('a, 'err) t
val fail_cause : 'err Cause.t -> ('a, 'err) t
val sandbox : ('a, 'err) t -> (('a, 'err Cause.t) result, 'no_err) t
val unsandbox : (('a, 'err Cause.t) result, 'no_err) t -> ('a, 'err) t
val match_ :
  on_success:('a -> 'b) -> on_failure:('err -> 'b) -> ('a, 'err) t -> ('b, 'outer_err) t
val match_effect :
  on_success:('a -> ('b, 'err2) t) ->
  on_failure:('err -> ('b, 'err2) t) ->
  ('a, 'err) t ->
  ('b, 'err2) t
val uninterruptible : ('a, 'err) t -> ('a, 'err) t
val retry : Schedule.t -> ('err -> bool) -> ('a, 'err) t -> ('a, 'err) t
val repeat : Schedule.t -> (unit, 'err) t -> (unit, 'err) t
val with_background :
  ?name:string -> (unit, 'err) t -> (unit -> ('a, 'err) t) -> ('a, 'err) t
val daemon : (unit, 'err) t -> (unit, 'err) t
val fork : ('a, 'err) t -> (('a, 'err) Fiber.t, 'outer_err) t
val fork_scoped : ('a, 'err) t -> (('a, 'err) Fiber.t, 'outer_err) t
val fork_daemon : (unit, 'err) t -> (unit, 'outer_err) t

val acquire_use_release :
  acquire:('a, 'err) t ->
  release:('a -> (unit, 'cleanup_err) t) ->
  ('a -> ('b, 'err) t) ->
  ('b, 'err) t

val supervisor_scoped :
  ?max_failures:int -> ('a, 'err) supervisor_body -> ('a, 'err) t

val supervisor_pure : 'a -> ('s, 'a, 'err) supervisor_scope
val supervisor_lift : ('a, 'err) t -> ('s, 'a, 'err) supervisor_scope
val supervisor_fail : 'err -> ('s, 'a, 'err) supervisor_scope

val supervisor_bind :
  ('a -> ('s, 'b, 'err) supervisor_scope) ->
  ('s, 'a, 'err) supervisor_scope ->
  ('s, 'b, 'err) supervisor_scope

val supervisor_start :
  ('s, 'err) supervisor ->
  ('s, 'a, 'err) supervisor_scope ->
  ('s, ('s, 'err, 'a) supervisor_child, 'outer_err) supervisor_scope

val supervisor_await :
  ('s, 'err, 'a) supervisor_child -> ('s, 'a, 'err) supervisor_scope

val supervisor_cancel :
  ('s, 'err, 'a) supervisor_child -> ('s, unit, 'err) supervisor_scope

val supervisor_failures :
  ('s, 'err) supervisor -> ('s, 'err Cause.t list, 'outer_err) supervisor_scope

val supervisor_check :
  ('s, [> `Supervisor_failed of int ] as 'err) supervisor ->
  ('s, unit, 'err) supervisor_scope

val supervisor_yield : ('s, unit, 'err) supervisor_scope

module Expert : sig
  type context = Effect_core.context

  val scheduler : context -> Scheduler.t

  val async_leaf :
    ?name:string ->
    (context ->
     resume:(('a, 'err) Exit.t -> unit) ->
     on_cancel:((unit -> unit) -> unit) ->
     unit) ->
    ('a, 'err) t
end
