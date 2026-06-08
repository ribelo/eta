type ('env, 'err, 'a) effect =
  | Thunk : string * ('env -> 'a) -> ('env, _, 'a) effect

let portable_thunk name (f : ('env -> 'a) @ portable) = Thunk (name, f)

let bad () =
  let counter = ref 0 in
  portable_thunk "capturing-ref" (fun env ->
      incr counter;
      env)

