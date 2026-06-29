(** Tiny lock for Eta-owned in-memory state.

    This is deliberately not a condition variable or scheduler primitive. Use
    it only around short critical sections that do not perform effects, sleeps,
    promise awaits, or user callbacks. Runtime-owned blocking waits belong in
    [Runtime_contract]. *)

type t

val create : unit -> t
val lock : t -> unit
(** Acquire [t]. Raises [Invalid_argument] if the current domain already owns
    [t]. *)

val unlock : t -> unit
(** Release [t]. Raises [Invalid_argument] when called by a non-owner or when
    [t] is not locked. *)

val use : t -> (unit -> 'a) -> 'a
