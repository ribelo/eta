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

(* The owner is the immediate domain identity rather than [Domain.id option]:
   an unboxed field keeps acquisition allocation-free and lets the atomic
   store avoid the pointer write barrier. [no_owner] is not a valid
   [Domain.id], which is always non-negative. *)
type t = {
  mutex : Mutex.t;
  owner : int Atomic.t;
}

let no_owner = -1
let create () = { mutex = Mutex.create (); owner = Atomic.make no_owner }
let[@inline always] self_id () = (Domain.self () :> int)

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

let lock_as t current =
  if Atomic.get t.owner = current then invalid_arg reentrant_message;
  Mutex.lock t.mutex;
  Atomic.set t.owner current;
  enter_critical_section ()

let unlock_as t current =
  let owner = Atomic.get t.owner in
  if owner = current then (
    leave_critical_section ();
    Atomic.set t.owner no_owner;
    Mutex.unlock t.mutex)
  else if owner = no_owner then
    invalid_arg "Eta.Sync_lock: unlock of unlocked lock"
  else invalid_arg "Eta.Sync_lock: unlock from non-owner domain"

let[@inline always] use t (f @ local once) =
  let current = self_id () in
  lock_as t current;
  try
    let result = f () in
    unlock_as t current;
    result
  with exn ->
    unlock_as t current;
    raise exn
