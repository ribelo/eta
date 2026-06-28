open Effet

let program () =
  Env_m16.program ()
  |> Effect.bind (fun acc -> Effect.named "notify_run" (Effect.sync (fun env -> env#notify_run acc)))
