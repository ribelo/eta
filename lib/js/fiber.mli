type ('a, 'err) t

val id : ('a, 'err) t -> int
val await : ('a, 'err) t -> (('a, 'err Cause.t) result, 'outer_err) Effect_core.t
val join : ('a, 'err) t -> ('a, 'err) Effect_core.t
val interrupt : ('a, 'err) t -> (unit, 'outer_err) Effect_core.t
val poll : ('a, 'err) t -> ('a, 'err Cause.t) result option
val fork : ('a, 'err) Effect_core.t -> (('a, 'err) t, 'outer_err) Effect_core.t
val fork_scoped : ('a, 'err) Effect_core.t -> (('a, 'err) t, 'outer_err) Effect_core.t
val fork_daemon : (unit, 'err) Effect_core.t -> (unit, 'outer_err) Effect_core.t
