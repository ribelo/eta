(** Backend-neutral one-shot cells.

    The first [resolve] wins and wakes every current waiter; later calls return
    [false]. [await] preserves the winning [Exit.t], so typed failures and
    defects retain their original cause. A cancelled waiter is removed without
    consuming the result, while other and later waiters can still observe it.
    If cancellation removes a waiter first, it remains interrupted; if
    resolution is stored first, it observes that exit even when cancellation
    precedes backend wake delivery. Closing an owning cancellation boundary
    interrupts its waiter through ordinary Eta cancellation; the cell remains
    usable and may be resolved afterward. *)

type ('a, 'err) t

val create : unit -> ('a, 'err) t
val await : ('a, 'err) t -> ('a, 'err) Effect.t
val resolve : ('a, 'err) t -> ('a, 'err) Exit.t -> (bool, 'outer) Effect.t
