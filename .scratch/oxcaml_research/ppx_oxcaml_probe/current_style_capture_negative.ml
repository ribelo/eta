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

let leaked = ref "alice"

let current_user =
  Effect.thunk "auth.current_user" (fun _env -> !leaked)

let () =
  ignore current_user

