type 'a t

val make : ?label:string -> 'a -> 'a t
val value : 'a t -> 'a
val wipe_unsafe : 'a t -> bool
val label : 'a t -> string option
val pp : Format.formatter -> 'a t -> unit
val equal : ('a -> 'a -> bool) -> 'a t -> 'a t -> bool
val hash : ('a -> int) -> 'a t -> int
