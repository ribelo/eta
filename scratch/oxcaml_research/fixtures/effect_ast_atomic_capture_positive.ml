type ('env, 'err, 'a) effect =
  | Thunk : string * ('env -> 'a) -> ('env, _, 'a) effect

let portable_thunk name (f : ('env -> 'a) @ portable) = Thunk (name, f)

let ok () =
  let counter = Atomic.make 0 in
  portable_thunk "capturing-atomic" (fun env ->
      Atomic.incr counter;
      env)

let () = ignore (ok ())

