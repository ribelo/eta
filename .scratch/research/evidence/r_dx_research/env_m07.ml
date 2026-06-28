open Effet

let program () =
  Env_m06.program ()
  |> Effect.bind (fun acc -> Effect.named "billing_query" (Effect.sync (fun env -> env#billing_query acc)))
  |> Effect.bind (fun acc -> Effect.named "billing_get" (Effect.sync (fun env -> env#billing_get acc)))
