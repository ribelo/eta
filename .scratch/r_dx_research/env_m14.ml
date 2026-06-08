open Effet

let program () =
  Env_m13.program ()
  |> Effect.bind (fun acc -> Effect.named "search_fetch" (Effect.sync (fun env -> env#search_fetch acc)))

