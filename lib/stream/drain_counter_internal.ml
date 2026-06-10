type waiter = {
  contract : Eta.Runtime_contract.t;
  resolver : unit Eta.Runtime_contract.resolver;
  mutable active : bool;
}

type t = {
  mutex : Mutex.t;
  mutable count : int;
  mutable waiters : waiter list;
}

let create () = { mutex = Mutex.create (); count = 0; waiters = [] }

let with_lock counter f =
  Mutex.lock counter.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock counter.mutex) f

let value counter = with_lock counter (fun () -> counter.count)

let wake_waiters waiters =
  List.iter
    (fun waiter ->
      if waiter.active then (
        waiter.active <- false;
        waiter.contract.Eta.Runtime_contract.resolve_promise waiter.resolver ()))
    waiters

let compact_waiters counter =
  counter.waiters <- List.filter (fun waiter -> waiter.active) counter.waiters

let cancel_waiter counter waiter =
  if waiter.active then (
    waiter.active <- false;
    compact_waiters counter)

let incr_by counter n =
  if n < 0 then invalid_arg "Drain_counter.incr_by: n must be >= 0";
  if n > 0 then with_lock counter (fun () -> counter.count <- counter.count + n)

let decr_by counter n =
  if n < 0 then invalid_arg "Drain_counter.decr_by: n must be >= 0";
  if n > 0 then
    let waiters =
      with_lock counter @@ fun () ->
      if n > counter.count then invalid_arg "Drain_counter.decr_by: underflow";
      counter.count <- counter.count - n;
      if counter.count = 0 then (
        let waiters = counter.waiters in
        counter.waiters <- [];
        waiters)
      else []
    in
    wake_waiters waiters

let incr counter = incr_by counter 1
let decr counter = decr_by counter 1

let enqueue_waiter contract counter =
  let promise, resolver = contract.Eta.Runtime_contract.create_promise () in
  let waiter = { contract; resolver; active = true } in
  counter.waiters <- waiter :: counter.waiters;
  (promise, waiter)

let await_zero ?(name = "eta_stream.drain_counter.await_zero") counter =
  Eta.Effect.named name
    (Eta.Effect.Expert.make ~leaf_name:name @@ fun context ->
     let contract = Eta.Effect.Expert.contract context in
     let rec loop () =
       match
         with_lock counter @@ fun () ->
         if counter.count = 0 then `Ready
         else
           let promise, waiter = enqueue_waiter contract counter in
           `Wait (promise, waiter)
       with
       | `Ready -> Eta.Exit.Ok ()
       | `Wait (promise, waiter) -> (
           try
             contract.Eta.Runtime_contract.await_promise promise;
             loop ()
           with exn ->
             (match contract.Eta.Runtime_contract.cancellation_reason exn with
             | Some _ ->
                 contract.Eta.Runtime_contract.protect (fun () ->
                     with_lock counter (fun () -> cancel_waiter counter waiter))
             | None -> ());
             raise exn)
     in
     loop ())
