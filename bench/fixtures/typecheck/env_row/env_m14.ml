open Effet

let program () =
  Env_m13.program ()
  |> Effect.bind (fun acc -> Effect.thunk "search_fetch" (fun env -> env#search_fetch acc))
