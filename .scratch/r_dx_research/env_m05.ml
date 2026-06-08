open Effet

let program () =
  Env_m04.program ()
  |> Effect.bind (fun acc -> Effect.named "cache_query" (Effect.sync (fun env -> env#cache_query acc)))
  |> Effect.bind (fun acc -> Effect.named "cache_get" (Effect.sync (fun env -> env#cache_get acc)))

