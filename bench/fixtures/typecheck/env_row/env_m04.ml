open Effet

let program () =
  Env_m03.program ()
  |> Effect.bind (fun acc -> Effect.thunk "order_run" (fun env -> env#order_run acc))
  |> Effect.bind (fun acc -> Effect.thunk "order_fetch" (fun env -> env#order_fetch acc))
