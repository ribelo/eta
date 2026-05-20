open Effet

let program () =
  Env_m10.program ()
  |> Effect.bind (fun acc -> Effect.thunk "search_query" (fun env -> env#search_query acc))
