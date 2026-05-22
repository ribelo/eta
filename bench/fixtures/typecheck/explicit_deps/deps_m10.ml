open Eta

let program deps =
  Deps_m09.program deps
  |> Effect.bind (fun acc -> Effect.sync "audit_run" (fun () -> deps#audit_run acc))
  |> Effect.bind (fun acc -> Effect.sync "audit_fetch" (fun () -> deps#audit_fetch acc))
