(** JavaScript-runtime mutable cells. *)

type 'a t

val make : 'a -> 'a t
val get : 'a t -> 'a
val set : 'a t -> 'a -> unit
val update : 'a t -> ('a -> 'a) -> unit
val update_and_get : 'a t -> ('a -> 'a) -> 'a
val get_and_set : 'a t -> 'a -> 'a
val compare_and_set : 'a t -> 'a -> 'a -> bool
val incr : int t -> unit
val decr : int t -> unit
