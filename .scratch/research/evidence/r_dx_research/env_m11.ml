open Effet

let program () =
  Env_m10.program ()
  |> Effect.bind (fun acc -> Effect.named "search_query" (Effect.sync (fun env -> env#search_query acc)))
