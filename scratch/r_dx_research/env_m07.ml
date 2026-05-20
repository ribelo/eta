open Effet

let program () =
  Env_m06.program ()
  |> Effect.bind (fun acc -> Effect.sync "billing_query" (fun env -> env#billing_query acc))
  |> Effect.bind (fun acc -> Effect.sync "billing_get" (fun env -> env#billing_get acc))

