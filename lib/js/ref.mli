type 'a t

val make : 'a -> ('a t, 'err) Effect_core.t
val make_unsafe : 'a -> 'a t
val get : 'a t -> ('a, 'err) Effect_core.t
val set : 'a t -> 'a -> (unit, 'err) Effect_core.t
val update : 'a t -> ('a -> 'a) -> (unit, 'err) Effect_core.t
val get_and_set : 'a t -> 'a -> ('a, 'err) Effect_core.t
val update_and_get : 'a t -> ('a -> 'a) -> ('a, 'err) Effect_core.t
val modify : 'a t -> ('a -> 'b * 'a) -> ('b, 'err) Effect_core.t
