open Effet

let program () =
  Env_m02.program ()
  |> Effect.bind (fun acc -> Effect.sync "order_query" (fun env -> env#order_query acc))
  |> Effect.bind (fun acc -> Effect.sync "order_get" (fun env -> env#order_get acc))

