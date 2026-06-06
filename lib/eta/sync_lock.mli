(** Tiny lock for Eta-owned in-memory state.

    This is deliberately not a condition variable or scheduler primitive. Use
    it only around short critical sections that do not perform effects, sleeps,
    promise awaits, or user callbacks. Runtime-owned blocking waits belong in
    [Runtime_contract]. *)

type t

val create : unit -> t
val lock : t -> unit
val unlock : t -> unit
val use : t -> (unit -> 'a) -> 'a
