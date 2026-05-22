open Eta

let program () =
  Env_m11.program ()
  |> Effect.bind (fun acc -> Effect.sync "search_get" (fun env -> env#search_get acc))
