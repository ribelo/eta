type ('env, 'err, 'a) effect =
  | Pure : 'a -> (_, _, 'a) effect
  | Thunk : string * ('env -> 'a) -> ('env, _, 'a) effect
  | Bind :
      ('env, 'err, 'b) effect * ('b -> ('env, 'err, 'a) effect)
      -> ('env, 'err, 'a) effect
  | Catch :
      ('env, 'err1, 'a) effect * ('err1 -> ('env, 'err2, 'a) effect)
      -> ('env, 'err2, 'a) effect

let thunk name f = Thunk (name, f)
let bind k e = Bind (e, k)
let catch h e = Catch (e, h)

let program : (int, [ `Error ], int) effect =
 thunk "read" (fun env -> env)
 |> bind (fun value -> Pure (value + 1))
 |> catch (fun _ -> Pure 0)

let () = ignore program
