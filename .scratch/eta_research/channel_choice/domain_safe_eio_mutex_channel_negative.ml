type t = {
  mutex : Eio.Mutex.t;
  condition : Eio.Condition.t;
  mutable count : int;
}

let ch =
  { mutex = Eio.Mutex.create (); condition = Eio.Condition.create (); count = 0 }

let touch () =
  Eio.Mutex.lock ch.mutex;
  ch.count <- ch.count + 1;
  Eio.Mutex.unlock ch.mutex

let () =
  let domain = Domain.Safe.spawn touch in
  Domain.join domain
