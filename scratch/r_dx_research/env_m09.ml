open Effet

let program () =
  Env_m08.program ()
  |> Effect.bind (fun acc -> Effect.sync "audit_query" (fun env -> env#audit_query acc))
  |> Effect.bind (fun acc -> Effect.sync "audit_get" (fun env -> env#audit_get acc))

