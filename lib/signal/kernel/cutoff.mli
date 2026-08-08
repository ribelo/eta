type 'a t

val suppress : 'a t -> published:'a -> candidate:'a -> bool
val always : 'a t
val never : 'a t
val phys_equal : 'a t
val of_equal : ('a -> 'a -> bool) -> 'a t
val of_compare : ('a -> 'a -> int) -> 'a t
