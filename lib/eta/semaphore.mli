(** Cancellation-safe counting semaphore.

    Semaphore owns bounded permits with blocking acquire, cancellation-safe
    waiters, and ordered wake. It is a public primitive extracted from the
    wait-slot mechanism that previously lived inside {!Pool}.

    Out of scope for v1: PartitionedSemaphore, effectful permit counts, and
    configurable fairness (inherits FIFO from the wait queue). *)

type t

val make : permits:int -> t
(** Create a semaphore with [permits] available permits.
    @raise Invalid_argument if [permits <= 0]. *)

val try_acquire : t -> int -> bool
(** [try_acquire t n] attempts to acquire [n] permits without blocking.
    Returns [true] if permits were available and atomically decremented,
    [false] otherwise.
    @raise Invalid_argument if [n <= 0] or [n] exceeds the semaphore capacity. *)

val acquire : t -> int -> (unit, 'err) Effect.t
(** [acquire t n] blocks until [n] permits are available, then atomically
    decrements the available count by [n].

    Cancellation-safe: if the calling fiber is cancelled while waiting, the
    waiter slot is removed and no permits are consumed.
    @raise Invalid_argument if [n <= 0] or [n] exceeds the semaphore capacity. *)

val release : t -> int -> unit
(** [release t n] returns [n] permits. Never blocks. Wakes waiters whose
    requests can now be satisfied.

    @raise Invalid_argument if [n <= 0] or if the release would exceed the
    semaphore capacity. *)

val with_permits : t -> int -> (unit -> ('a, 'err) Effect.t) -> ('a, 'err) Effect.t
(** [with_permits t n f] acquires [n] permits, runs [f ()], and releases the
    permits on exit (success, typed failure, or cancellation). *)

val acquire_or_abort :
  t -> int -> abort:('a, 'err) Effect.t -> (bool, 'err) Effect.t
(** [acquire_or_abort t n ~abort] races acquiring [n] permits against [abort].
    Returns [true] if the permits were acquired, or [false] if [abort] produced
    a value first.

    Unlike racing {!acquire} against a signal directly, a lost acquisition never
    leaks capacity: if the acquisition concurrently claimed its permits but lost
    the race, those permits are released before returning [false].
    @raise Invalid_argument if [n <= 0] or [n] exceeds the semaphore capacity. *)

val available : t -> int
(** Current available permit count. May race with other fibers. *)

val waiting : t -> int
(** Number of fibers currently blocked waiting for permits. May race. *)

val cancelled_waiters : t -> int
(** Cumulative count of waiters removed by cancellation. May race. *)
