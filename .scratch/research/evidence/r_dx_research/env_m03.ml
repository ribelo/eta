open Effet

let program () =
  Env_m02.program ()
  |> Effect.bind (fun acc -> Effect.named "order_query" (Effect.sync (fun env -> env#order_query acc)))
  |> Effect.bind (fun acc -> Effect.named "order_get" (Effect.sync (fun env -> env#order_get acc)))
