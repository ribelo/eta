type waiter = {
  requested : int;
  mutable active : bool;
  resume : unit -> unit;
}

type t = {
  capacity : int;
  mutable available : int;
  mutable waiters : waiter Stdlib.Queue.t;
  mutable waiting : int;
  mutable cancelled_waiters : int;
}

let make ~permits =
  if permits <= 0 then invalid_arg "Eta_js.Semaphore.make: permits must be > 0";
  {
    capacity = permits;
    available = permits;
    waiters = Stdlib.Queue.create ();
    waiting = 0;
    cancelled_waiters = 0;
  }

let validate_request t n =
  if n <= 0 then invalid_arg "Eta_js.Semaphore: permit count must be > 0";
  if n > t.capacity then
    invalid_arg "Eta_js.Semaphore: permit count exceeds capacity"

let try_acquire t n =
  validate_request t n;
  if t.waiting = 0 && t.available >= n then begin
    t.available <- t.available - n;
    true
  end
  else false

let wake_waiters t =
  let next_waiters = Stdlib.Queue.create () in
  let blocked = ref false in
  while not (Stdlib.Queue.is_empty t.waiters) do
    let waiter = Stdlib.Queue.take t.waiters in
    if waiter.active then
      if (not !blocked) && waiter.requested <= t.available then begin
        waiter.active <- false;
        t.waiting <- t.waiting - 1;
        t.available <- t.available - waiter.requested;
        waiter.resume ()
      end
      else begin
        blocked := true;
        Stdlib.Queue.add waiter next_waiters
      end
  done;
  t.waiters <- next_waiters

let release t n =
  validate_request t n;
  if t.available > t.capacity - n then
    invalid_arg "Eta_js.Semaphore.release: release exceeds capacity";
  t.available <- t.available + n;
  wake_waiters t

let cancel_waiter t waiter =
  if waiter.active then begin
    waiter.active <- false;
    t.waiting <- t.waiting - 1;
    t.cancelled_waiters <- t.cancelled_waiters + 1
  end

let acquire t n =
  validate_request t n;
  if try_acquire t n then Effect.unit
  else
    Effect.Expert.async_leaf (fun _context ~resume ~on_cancel ->
        let waiter =
          {
            requested = n;
            active = true;
            resume = (fun () -> resume (Exit.ok ()));
          }
        in
        Stdlib.Queue.add waiter t.waiters;
        t.waiting <- t.waiting + 1;
        on_cancel (fun () -> cancel_waiter t waiter))

let with_permits t n f =
  Effect.bind
    (fun () ->
      Effect.finally (Effect.sync (fun () -> release t n)) (f ()))
    (acquire t n)

let with_permits_or_abort t n ~abort f =
  Effect.bind
    (function
      | `Acquired ->
          Effect.map (fun value -> Some value) (with_permits t n f)
      | `Aborted -> Effect.pure None)
    (Effect.race
       [
         Effect.map (fun () -> `Acquired) (acquire t n);
         Effect.map (fun _ -> `Aborted) abort;
       ])

let available t = t.available
let waiting t = t.waiting
let cancelled_waiters t = t.cancelled_waiters
