open Effet

let program () =
  Env_m09.program ()
  |> Effect.bind (fun acc -> Effect.sync "audit_run" (fun env -> env#audit_run acc))
  |> Effect.bind (fun acc -> Effect.sync "audit_fetch" (fun env -> env#audit_fetch acc))

