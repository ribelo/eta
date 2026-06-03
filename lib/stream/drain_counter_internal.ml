type t = {
  mutex : Eio.Mutex.t;
  condition : Eio.Condition.t;
  mutable count : int;
}

let create () =
  { mutex = Eio.Mutex.create (); condition = Eio.Condition.create (); count = 0 }

let value counter = Eio.Mutex.use_ro counter.mutex (fun () -> counter.count)

let incr_by counter n =
  if n < 0 then invalid_arg "Drain_counter.incr_by: n must be >= 0";
  if n > 0 then
    Eio.Mutex.use_rw ~protect:false counter.mutex (fun () ->
        counter.count <- counter.count + n)

let decr_by counter n =
  if n < 0 then invalid_arg "Drain_counter.decr_by: n must be >= 0";
  if n > 0 then
    Eio.Mutex.use_rw ~protect:false counter.mutex (fun () ->
        if n > counter.count then invalid_arg "Drain_counter.decr_by: underflow";
        counter.count <- counter.count - n;
        if counter.count = 0 then Eio.Condition.broadcast counter.condition)

let incr counter = incr_by counter 1
let decr counter = decr_by counter 1

let await_zero ?(name = "eta_stream.drain_counter.await_zero") counter =
  Eta.Effect.named name
    (Eta.Effect.sync (fun () ->
         Eio.Mutex.use_ro counter.mutex (fun () ->
             while counter.count <> 0 do
               Eio.Condition.await counter.condition counter.mutex
             done)))
