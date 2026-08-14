type context = { mutable state : int }

let consume : context @ unique -> unit = fun _ -> ()

let delayed (x @ unique) : (unit -> unit) @ once = fun () -> consume x

let cross_portable (type a : value mod portable)
    (x : a @ nonportable) : a @ portable =
  x

let local_read n =
  let local_ r = ref n in
  !r

let spawn f = Domain.Safe.spawn f
