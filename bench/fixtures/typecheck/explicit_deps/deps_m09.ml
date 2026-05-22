open Eta

let program deps =
  Deps_m08.program deps
  |> Effect.bind (fun acc -> Effect.sync "audit_query" (fun () -> deps#audit_query acc))
  |> Effect.bind (fun acc -> Effect.sync "audit_get" (fun () -> deps#audit_get acc))
