open Effet

let program () =
  Env_m15.program ()
  |> Effect.bind (fun acc -> Effect.named "notify_get" (Effect.sync (fun env -> env#notify_get acc)))

