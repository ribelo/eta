open Effet

let program () =
  Env_m01.program ()
  |> Effect.bind (fun acc -> Effect.sync "user_run" (fun env -> env#user_run acc))
  |> Effect.bind (fun acc -> Effect.sync "user_fetch" (fun env -> env#user_fetch acc))

