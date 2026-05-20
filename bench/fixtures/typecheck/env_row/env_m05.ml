open Effet

let program () =
  Env_m04.program ()
  |> Effect.bind (fun acc -> Effect.thunk "cache_query" (fun env -> env#cache_query acc))
  |> Effect.bind (fun acc -> Effect.thunk "cache_get" (fun env -> env#cache_get acc))
