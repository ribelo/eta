type 'a t

val make : 'a -> ('a t, 'err) Effect_core.t
val make_unsafe : 'a -> 'a t
val get : 'a t -> ('a, 'err) Effect_core.t
val update_effect : 'a t -> ('a -> ('a, 'err) Effect_core.t) -> (unit, 'err) Effect_core.t
val modify_effect : 'a t -> ('a -> ('b * 'a, 'err) Effect_core.t) -> ('b, 'err) Effect_core.t
