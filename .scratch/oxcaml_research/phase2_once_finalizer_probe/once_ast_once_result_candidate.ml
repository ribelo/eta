(* Candidate F: a consuming AST interpreter returns its success value at once
   mode. This checks whether the Pure extraction problem is only the old many
   result contract or whether ordinary consumers become unusable. *)

type ('env, 'err, 'a) t =
  | Pure : 'a -> ('env, 'err, 'a) t
  | Acquire_release :
      {
        acquire : ('env, 'err, 'a) t;
        release : 'a -> ('env, 'err, unit) t @@ once;
      }
      -> ('env, 'err, 'a) t

let pure value = Pure value
let acquire_release ~acquire ~release = Acquire_release { acquire; release }

let rec run : type env err a. (env, err, a) t @ once -> a @ once = function
  | Pure value -> value
  | Acquire_release { acquire; release } ->
      let (value @ once) = run acquire in
      ignore (run (release value));
      value

let () =
  let (release @ once) _ = pure () in
  let (value @ once) = run (acquire_release ~acquire:(pure 1) ~release) in
  if value <> 1 then failwith "unexpected result"
