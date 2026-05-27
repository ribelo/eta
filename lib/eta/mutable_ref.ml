type 'a t = { cell : 'a Atomic.t } [@@unboxed]

let make v = { cell = Atomic.make v }
let get t = Atomic.get t.cell
let set t v = Atomic.set t.cell v
let compare_and_set t expected desired = Atomic.compare_and_set t.cell expected desired
let get_and_set t v = Atomic.exchange t.cell v

let update t f =
  let rec loop () =
    let old = Atomic.get t.cell in
    let new_ = f old in
    if Atomic.compare_and_set t.cell old new_ then ()
    else loop ()
  in
  loop ()

let update_and_get t f =
  let rec loop () =
    let old = Atomic.get t.cell in
    let new_ = f old in
    if Atomic.compare_and_set t.cell old new_ then new_
    else loop ()
  in
  loop ()

let incr t = update t (fun x -> x + 1)
let decr t = update t (fun x -> x - 1)
