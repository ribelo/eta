open Effet

let program () =
  Env_m09.program ()
  |> Effect.bind (fun acc -> Effect.named "audit_run" (Effect.sync (fun env -> env#audit_run acc)))
  |> Effect.bind (fun acc -> Effect.named "audit_fetch" (Effect.sync (fun env -> env#audit_fetch acc)))

