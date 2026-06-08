open Effet

let program () =
  Env_m03.program ()
  |> Effect.bind (fun acc -> Effect.named "order_run" (Effect.sync (fun env -> env#order_run acc)))
  |> Effect.bind (fun acc -> Effect.named "order_fetch" (Effect.sync (fun env -> env#order_fetch acc)))

