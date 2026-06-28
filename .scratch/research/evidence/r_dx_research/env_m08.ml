open Effet

let program () =
  Env_m07.program ()
  |> Effect.bind (fun acc -> Effect.named "billing_run" (Effect.sync (fun env -> env#billing_run acc)))
  |> Effect.bind (fun acc -> Effect.named "billing_fetch" (Effect.sync (fun env -> env#billing_fetch acc)))
