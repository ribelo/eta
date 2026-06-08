open Effet

let program () =
  Env_m12.program ()
  |> Effect.bind (fun acc -> Effect.named "search_run" (Effect.sync (fun env -> env#search_run acc)))

