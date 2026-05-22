open Effet

let program () =
  Env_m05.program ()
  |> Effect.bind (fun acc -> Effect.named "cache_run" (Effect.sync (fun env -> env#cache_run acc)))
  |> Effect.bind (fun acc -> Effect.named "cache_fetch" (Effect.sync (fun env -> env#cache_fetch acc)))

