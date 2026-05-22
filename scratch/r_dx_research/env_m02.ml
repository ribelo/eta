open Effet

let program () =
  Env_m01.program ()
  |> Effect.bind (fun acc -> Effect.named "user_run" (Effect.sync (fun env -> env#user_run acc)))
  |> Effect.bind (fun acc -> Effect.named "user_fetch" (Effect.sync (fun env -> env#user_fetch acc)))

