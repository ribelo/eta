open Eta

let program deps =
  Deps_m06.program deps
  |> Effect.bind (fun acc -> Effect.sync "billing_query" (fun () -> deps#billing_query acc))
  |> Effect.bind (fun acc -> Effect.sync "billing_get" (fun () -> deps#billing_get acc))
