open Effet

let program () =
  Env_m08.program ()
  |> Effect.bind (fun acc -> Effect.named "audit_query" (Effect.sync (fun env -> env#audit_query acc)))
  |> Effect.bind (fun acc -> Effect.named "audit_get" (Effect.sync (fun env -> env#audit_get acc)))

