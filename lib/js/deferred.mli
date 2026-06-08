type ('a, 'err) t

val make : unit -> (('a, 'err) t, 'outer_err) Effect_core.t
val make_unsafe : unit -> ('a, 'err) t
val await : ('a, 'err) t -> ('a, 'err) Effect_core.t
val poll : ('a, 'err) t -> ('a, 'err Cause.t) result option
val done_ : ('a, 'err) t -> ('a, 'err) Exit.t -> (bool, 'outer_err) Effect_core.t
val succeed : ('a, 'err) t -> 'a -> (bool, 'outer_err) Effect_core.t
val fail : ('a, 'err) t -> 'err -> (bool, 'outer_err) Effect_core.t
val fail_cause : ('a, 'err) t -> 'err Cause.t -> (bool, 'outer_err) Effect_core.t
val interrupt : ('a, 'err) t -> (bool, 'outer_err) Effect_core.t
