type waiter_state = Waiting | Resolved_unclaimed | Claimed | Cancelled

type waiter = {
  permits : int;
  contract : Runtime_contract.t;
  resolver : unit Runtime_contract.resolver;
  mutable state : waiter_state;
}

type t = {
  max_permits : int;
  mutex : Sync_lock.t;
  mutable available : int;
  waiters : waiter Stdlib.Queue.t;
  mutable cancelled_waiters : int;
}

let make ~permits =
  if permits <= 0 then invalid_arg "Eta.Semaphore.make: permits must be > 0";
  {
    max_permits = permits;
    mutex = Sync_lock.create ();
    available = permits;
    waiters = Stdlib.Queue.create ();
    cancelled_waiters = 0;
  }

let available t = Sync_lock.use t.mutex @@ fun () -> t.available
let waiting t =
  Sync_lock.use t.mutex @@ fun () ->
  let count = ref 0 in
  Stdlib.Queue.iter
    (fun waiter -> match waiter.state with Waiting -> incr count | _ -> ())
    t.waiters;
  !count

let cancelled_waiters t =
  Sync_lock.use t.mutex @@ fun () -> t.cancelled_waiters

let with_lock t f =
  Sync_lock.use t.mutex f

let with_lock_during_cancel contract t f =
  contract.Runtime_contract.protect (fun () -> with_lock t f)

let validate_request name t n =
  if n <= 0 || n > t.max_permits then
    invalid_arg
      ("Eta.Semaphore." ^ name ^ ": n must be between 1 and max_permits")

let rec take_ready_waiter t =
  if Stdlib.Queue.is_empty t.waiters then None
  else
    let waiter = Stdlib.Queue.peek t.waiters in
    match waiter.state with
    | Waiting when t.available >= waiter.permits ->
        ignore (Stdlib.Queue.take t.waiters : waiter);
        Some waiter
    | Waiting -> None
    | Resolved_unclaimed | Claimed | Cancelled ->
        ignore (Stdlib.Queue.take t.waiters : waiter);
        take_ready_waiter t

let compact_cancelled_waiters_locked t =
  if t.cancelled_waiters > 0 then (
    let live = Stdlib.Queue.create () in
    Stdlib.Queue.iter
      (fun waiter ->
        match waiter.state with
        | Cancelled -> ()
        | Waiting | Resolved_unclaimed | Claimed -> Stdlib.Queue.push waiter live)
      t.waiters;
    Stdlib.Queue.clear t.waiters;
    Stdlib.Queue.iter (fun waiter -> Stdlib.Queue.push waiter t.waiters) live)

let rec wake_waiters_locked t =
  match take_ready_waiter t with
  | None -> ()
  | Some waiter ->
      t.available <- t.available - waiter.permits;
      waiter.state <- Resolved_unclaimed;
      waiter.contract.Runtime_contract.resolve_promise waiter.resolver ();
      wake_waiters_locked t

let try_acquire t n =
  validate_request "try_acquire" t n;
  with_lock t @@ fun () ->
  compact_cancelled_waiters_locked t;
  wake_waiters_locked t;
  if not (Stdlib.Queue.is_empty t.waiters) then false
  else if t.available >= n then (
    t.available <- t.available - n;
    true)
  else false

let release t n =
  if n <= 0 then invalid_arg "Eta.Semaphore.release: n must be > 0";
  with_lock t @@ fun () ->
  if t.available + n > t.max_permits then
    invalid_arg "Eta.Semaphore.release: release would exceed semaphore capacity";
  t.available <- t.available + n;
  wake_waiters_locked t

let acquire t n =
  validate_request "acquire" t n;
  Effect_erasure.effect_to_public
    (Effect_core.sync_frame (fun frame ->
         let contract = frame.Effect_core.runtime.Runtime_core.contract in
         let promise, resolver = contract.Runtime_contract.create_promise () in
         let waiter = { permits = n; contract; resolver; state = Waiting } in
         with_lock t @@ fun () ->
         if t.available >= n then (
           t.available <- t.available - n;
           `Acquired)
         else (
           Stdlib.Queue.push waiter t.waiters;
           `Waiting (contract, promise, waiter))))
  |> Effect.bind (function
       | `Acquired -> Effect.unit
       | `Waiting (contract, promise, waiter) ->
         let cleanup () =
           Effect.sync (fun () ->
             with_lock_during_cancel contract t @@ fun () ->
             (* Invariant (validated): on cancellation a permit is returned
                only while the waiter has not yet taken ownership. [Waiting]
                was never granted a permit; [Resolved_unclaimed] was granted
                one that the fiber never claimed, so it is given back. Once
                [Claimed] (or already [Cancelled]) ownership has transferred to
                the caller and cleanup must NOT release — the caller (e.g.
                [with_permits], [with_permits_or_abort], or Pool) is
                responsible. *)
             match waiter.state with
             | Waiting ->
                 waiter.state <- Cancelled;
                 t.cancelled_waiters <- t.cancelled_waiters + 1;
                 compact_cancelled_waiters_locked t;
                 wake_waiters_locked t
             | Resolved_unclaimed ->
                 waiter.state <- Cancelled;
                 t.cancelled_waiters <- t.cancelled_waiters + 1;
                 t.available <- min t.max_permits (t.available + waiter.permits);
                 compact_cancelled_waiters_locked t;
                 wake_waiters_locked t
             | Claimed | Cancelled -> ())
         in
         Effect.scoped
           (Effect.acquire_release
              ~acquire:Effect.unit
              ~release:(fun () -> cleanup ())
           |> Effect.bind (fun () ->
                  Effect.sync (fun () ->
                      contract.Runtime_contract.await_promise promise;
                      with_lock t @@ fun () ->
                      match waiter.state with
                      | Resolved_unclaimed -> waiter.state <- Claimed
                      | Waiting | Claimed | Cancelled -> ()))))

let with_permits_or_abort t n ~abort (f) =
  (* [claimed] means this combinator owns a granted permit. The finalizer is the
     only release path, so permits cannot escape through a result that a race or
     parent cancellation later discards. *)
  let claimed = Atomic.make false in
  let release_claimed =
    Effect.sync (fun () ->
        if Atomic.compare_and_set claimed true false then release t n)
  in
  let body =
    Effect.race
      [ acquire t n |> Effect.map (fun () -> Atomic.set claimed true; true);
        abort |> Effect.map (fun _ -> false) ]
    |> Effect.bind (fun acquired ->
           if acquired then f () |> Effect.map Option.some else Effect.pure None)
  in
  Effect.finally release_claimed body

let with_permits t n (f) =
  Effect.scoped
    (Effect.acquire_release
       ~acquire:(acquire t n)
       ~release:(fun () -> Effect.sync (fun () -> release t n))
    |> Effect.bind (fun () -> f ()))
