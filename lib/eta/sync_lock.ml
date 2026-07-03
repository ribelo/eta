(** Tiny lock for Eta-owned in-memory state.

    This is deliberately not a condition variable or scheduler primitive. Use
    it only around short critical sections that do not perform effects, sleeps,
    promise awaits, or user callbacks. Runtime-owned blocking waits belong in
    [Runtime_contract].

    While the current domain is inside a [Sync_lock] critical section, Eta
    runtime operations that can suspend, wake fibers, or invoke callbacks fail
    fast instead of yielding under the lock. *)

type t = {
  locked : bool Atomic.t;
  owner : Domain.id option Atomic.t;
}

let create () = { locked = Atomic.make false; owner = Atomic.make None }

let reentrant_message = "Eta.Sync_lock: reentrant lock acquisition"
let runtime_operation_message =
  "Eta.Sync_lock: runtime operation attempted while holding lock"

let dls_new_key f =
  (Domain.DLS.new_key [@alert "-unsafe_multidomain"]) f

let dls_get key =
  (Domain.DLS.get [@alert "-unsafe_multidomain"]) key

let dls_set key value =
  (Domain.DLS.set [@alert "-unsafe_multidomain"]) key value

let critical_depth_key = dls_new_key (fun () -> 0)
let critical_depth () = dls_get critical_depth_key
let in_critical_section () = critical_depth () > 0

let check_no_runtime_operation () =
  if in_critical_section () then invalid_arg runtime_operation_message

let enter_critical_section () =
  dls_set critical_depth_key (critical_depth () + 1)

let leave_critical_section () =
  let depth = critical_depth () in
  if depth <= 1 then dls_set critical_depth_key 0
  else dls_set critical_depth_key (depth - 1)

let rec lock t =
  let current = Domain.self () in
  match Atomic.get t.owner with
  | Some owner when owner = current -> invalid_arg reentrant_message
  | _ ->
      if Atomic.compare_and_set t.locked false true then (
        Atomic.set t.owner (Some current);
        enter_critical_section ())
      else lock t

let unlock t =
  let current = Domain.self () in
  match Atomic.get t.owner with
  | Some owner when owner = current ->
      leave_critical_section ();
      Atomic.set t.owner None;
      Atomic.set t.locked false
  | Some _ -> invalid_arg "Eta.Sync_lock: unlock from non-owner domain"
  | None -> invalid_arg "Eta.Sync_lock: unlock of unlocked lock"

let use t f =
  lock t;
  Fun.protect ~finally:(fun () -> unlock t) f
