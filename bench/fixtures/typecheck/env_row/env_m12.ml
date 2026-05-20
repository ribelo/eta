open Effet

let program () =
  Env_m11.program ()
  |> Effect.bind (fun acc -> Effect.thunk "search_get" (fun env -> env#search_get acc))
