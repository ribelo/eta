open Eta

let program deps =
  Deps_m06.program deps
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#billing_query acc))
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#billing_get acc))
