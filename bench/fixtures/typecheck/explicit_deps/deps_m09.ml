open Eta

let program deps =
  Deps_m08.program deps
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#audit_query acc))
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#audit_get acc))
