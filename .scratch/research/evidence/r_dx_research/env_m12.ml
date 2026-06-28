open Effet

let program () =
  Env_m11.program ()
  |> Effect.bind (fun acc -> Effect.named "search_get" (Effect.sync (fun env -> env#search_get acc)))
