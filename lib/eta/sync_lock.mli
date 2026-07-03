(** Eta-internal tiny lock for Eta-owned in-memory state.

    This module is not an application synchronization API. It is exposed only
    for Eta libraries that share root runtime and queue invariants. This is
    deliberately not a condition variable or scheduler primitive. Use it only
    around short critical sections that do not perform effects, sleeps, promise
    awaits, or user callbacks. Runtime-owned blocking waits belong in
    [Runtime_contract].

    While the current domain is inside a [Sync_lock] critical section, Eta
    runtime operations that can suspend, wake fibers, or invoke callbacks fail
    fast instead of yielding under the lock. *)

type t

val create : unit -> t
val lock : t -> unit
(** Acquire [t]. Raises [Invalid_argument] if the current domain already owns
    [t]. *)

val unlock : t -> unit
(** Release [t]. Raises [Invalid_argument] when called by a non-owner or when
    [t] is not locked. *)

val use : t -> (unit -> 'a) -> 'a

val in_critical_section : unit -> bool
(** [true] while the current domain is executing a [Sync_lock] critical
    section. This is for Eta runtime guards, not for synchronization policy. *)

val check_no_runtime_operation : unit -> unit
(** Raise [Invalid_argument] when called inside a [Sync_lock] critical section.
    Runtime operations that can suspend, wake fibers, or invoke callbacks call
    this to enforce the no-yield rule at the operation boundary. *)
