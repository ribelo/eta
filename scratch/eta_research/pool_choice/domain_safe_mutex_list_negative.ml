type t = {
  mutex : Mutex.t;
  mutable values : int list;
}

let t = { mutex = Mutex.create (); values = [] }

let push t value =
  Mutex.lock t.mutex;
  t.values <- value :: t.values;
  Mutex.unlock t.mutex

let () =
  let domain = Domain.Safe.spawn (fun () -> push t 1) in
  Domain.join domain
