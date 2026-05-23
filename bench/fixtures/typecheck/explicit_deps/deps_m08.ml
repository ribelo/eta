open Eta

let program deps =
  Deps_m07.program deps
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#billing_run acc))
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#billing_fetch acc))
