open Effet

let program () =
  Env_m12.program ()
  |> Effect.bind (fun acc -> Effect.sync "search_run" (fun env -> env#search_run acc))

