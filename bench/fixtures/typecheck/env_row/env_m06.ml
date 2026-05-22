open Eta

let program () =
  Env_m05.program ()
  |> Effect.bind (fun acc -> Effect.sync "cache_run" (fun env -> env#cache_run acc))
  |> Effect.bind (fun acc -> Effect.sync "cache_fetch" (fun env -> env#cache_fetch acc))
