(** Tiny lock for Eta-owned in-memory state.

    This is deliberately not a condition variable or scheduler primitive. Use
    it only around short critical sections that do not perform effects, sleeps,
    promise awaits, or user callbacks. Runtime-owned blocking waits belong in
    [Runtime_contract]. *)

type t = {
  locked : bool Atomic.t;
  owner : Domain.id option Atomic.t;
}

let create () = { locked = Atomic.make false; owner = Atomic.make None }

let reentrant_message = "Eta.Sync_lock: reentrant lock acquisition"

let rec lock t =
  let current = Domain.self () in
  match Atomic.get t.owner with
  | Some owner when owner = current -> invalid_arg reentrant_message
  | _ ->
      if Atomic.compare_and_set t.locked false true then
        Atomic.set t.owner (Some current)
      else lock t

let unlock t =
  let current = Domain.self () in
  match Atomic.get t.owner with
  | Some owner when owner = current ->
      Atomic.set t.owner None;
      Atomic.set t.locked false
  | Some _ -> invalid_arg "Eta.Sync_lock: unlock from non-owner domain"
  | None -> invalid_arg "Eta.Sync_lock: unlock of unlocked lock"

let use t f =
  lock t;
  Fun.protect ~finally:(fun () -> unlock t) f
