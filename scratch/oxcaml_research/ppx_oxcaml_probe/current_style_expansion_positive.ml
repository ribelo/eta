open! Portable

module Effect = struct
  type ('env : value mod portable, 'a : immutable_data) t =
    | Thunk : string * ('env -> 'a) @@ portable -> ('env, 'a) t

  let thunk name (body @ portable) =
    Thunk (name, body)
end

type env : immutable_data = {
  auth : string;
}

let current_user =
  Effect.thunk "auth.current_user" (fun env ->
    let auth = (env.auth : string) in
    auth)

let () =
  match current_user with
  | Effect.Thunk (_, body) ->
      if body { auth = "alice" } <> "alice" then failwith "bad expansion"

