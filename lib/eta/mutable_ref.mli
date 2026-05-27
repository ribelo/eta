(** Named shared mutable cell backed by {!Atomic.t}.

    This is a zero-allocation wrapper ([@@unboxed]) that documents intent:
    "this is shared mutable state across fibers", not a counter, not an
    option, not a one-shot promise. *)

type 'a t

val make : 'a -> 'a t
val get : 'a t -> 'a
val set : 'a t -> 'a -> unit
val update : 'a t -> ('a -> 'a) -> unit
(** [update t f] applies [f] to the current value and stores the result,
    retrying on CAS failure until it succeeds. *)

val update_and_get : 'a t -> ('a -> 'a) -> 'a
(** Like [update] but returns the new value. *)

val get_and_set : 'a t -> 'a -> 'a
(** [get_and_set t v] atomically stores [v] and returns the previous value. *)

val compare_and_set : 'a t -> 'a -> 'a -> bool
(** [compare_and_set t expected desired] stores [desired] only if the current
    value is physically equal to [expected]. Returns [true] on success. *)

val incr : int t -> unit
val decr : int t -> unit
