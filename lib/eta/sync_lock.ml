(** Tiny lock for Eta-owned in-memory state.

    This is deliberately not a condition variable or scheduler primitive. Use
    it only around short critical sections that do not perform effects, sleeps,
    promise awaits, or user callbacks. Runtime-owned blocking waits belong in
    [Runtime_contract]. *)

type t = { locked : bool Atomic.t }

let create () = { locked = Atomic.make false }

let rec lock t =
  if not (Atomic.compare_and_set t.locked false true) then lock t

let unlock t = Atomic.set t.locked false

let use t f =
  lock t;
  Fun.protect ~finally:(fun () -> unlock t) f
