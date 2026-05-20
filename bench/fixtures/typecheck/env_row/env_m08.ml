open Effet

let program () =
  Env_m07.program ()
  |> Effect.bind (fun acc -> Effect.thunk "billing_run" (fun env -> env#billing_run acc))
  |> Effect.bind (fun acc -> Effect.thunk "billing_fetch" (fun env -> env#billing_fetch acc))
