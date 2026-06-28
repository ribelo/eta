open Effet

let program () =
  Env_m14.program ()
  |> Effect.bind (fun acc -> Effect.named "notify_query" (Effect.sync (fun env -> env#notify_query acc)))
