type waiter_state = Waiting | Resolved | Cancelled

type waiter = {
  permits : int;
  resolver : unit Eio.Promise.u;
  mutable state : waiter_state;
}

type t = {
  max_permits : int;
  mutex : Eio.Mutex.t;
  mutable available : int;
  waiters : waiter Queue.t;
  mutable cancelled_waiters : int;
}

let make ~permits =
  if permits <= 0 then invalid_arg "Eta.Semaphore.make: permits must be > 0";
  {
    max_permits = permits;
    mutex = Eio.Mutex.create ();
    available = permits;
    waiters = Queue.create ();
    cancelled_waiters = 0;
  }

let available t = Eio.Mutex.use_ro t.mutex @@ fun () -> t.available
let waiting t = Eio.Mutex.use_ro t.mutex @@ fun () -> Queue.length t.waiters

let cancelled_waiters t =
  Eio.Mutex.use_ro t.mutex @@ fun () -> t.cancelled_waiters

let with_lock t f =
  Eio.Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.mutex) f

let rec take_active_waiter q =
  if Queue.is_empty q then None
  else
    let waiter = Queue.take q in
    match waiter.state with
    | Waiting -> Some waiter
    | Resolved | Cancelled -> take_active_waiter q

let rec wake_waiters_locked t =
  match take_active_waiter t.waiters with
  | None -> ()
  | Some waiter when t.available >= waiter.permits ->
      t.available <- t.available - waiter.permits;
      waiter.state <- Resolved;
      Eio.Promise.resolve waiter.resolver ();
      wake_waiters_locked t
  | Some waiter ->
      let temp = Queue.create () in
      Queue.push waiter temp;
      Queue.transfer t.waiters temp;
      Queue.transfer temp t.waiters

let try_acquire t n =
  if n <= 0 then invalid_arg "Eta.Semaphore.try_acquire: n must be > 0";
  with_lock t @@ fun () ->
  if t.available >= n then (
    t.available <- t.available - n;
    true)
  else false

let release t n =
  with_lock t @@ fun () ->
  t.available <- min t.max_permits (t.available + n);
  wake_waiters_locked t

let acquire t n =
  if n <= 0 then invalid_arg "Eta.Semaphore.acquire: n must be > 0";
  let promise, resolver = Eio.Promise.create () in
  let waiter = { permits = n; resolver; state = Waiting } in
  Effect.sync (fun () ->
    with_lock t @@ fun () ->
    if t.available >= n then (
      t.available <- t.available - n;
      true)
    else (
      Queue.push waiter t.waiters;
      false))
  |> Effect.bind (fun got_now ->
       if got_now then Effect.unit
       else
         let cleanup () =
           Effect.sync (fun () ->
             with_lock t @@ fun () ->
             match waiter.state with
             | Waiting ->
                 waiter.state <- Cancelled;
                 t.cancelled_waiters <- t.cancelled_waiters + 1;
                 wake_waiters_locked t
             | Resolved | Cancelled -> ())
         in
         Effect.scoped
           (Effect.acquire_release
              ~acquire:Effect.unit
              ~release:(fun () -> cleanup ())
           |> Effect.bind (fun () ->
                  Effect.sync (fun () -> Eio.Promise.await promise))))

let with_permits t n f =
  Effect.scoped
    (Effect.acquire_release
       ~acquire:(acquire t n)
       ~release:(fun () -> Effect.sync (fun () -> release t n))
    |> Effect.bind (fun () -> f ()))
