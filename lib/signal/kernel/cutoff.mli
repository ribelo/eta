type ('a : value_or_null) t

val suppress : ('a : value_or_null). 'a t -> published:'a -> candidate:'a -> bool
val always : 'a t
val never : 'a t
val phys_equal : 'a t
val of_equal : ('a : value_or_null). ('a -> 'a -> bool) -> 'a t
val of_compare : ('a : value_or_null). ('a -> 'a -> int) -> 'a t
