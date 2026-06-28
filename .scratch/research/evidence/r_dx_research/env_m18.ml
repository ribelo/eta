open Effet

let program () =
  Env_m17.program ()
  |> Effect.bind (fun acc -> Effect.named "notify_fetch" (Effect.sync (fun env -> env#notify_fetch acc)))
