open Eta

let program deps =
  Deps_m07.program deps
  |> Effect.bind (fun acc -> Effect.sync "billing_run" (fun () -> deps#billing_run acc))
  |> Effect.bind (fun acc -> Effect.sync "billing_fetch" (fun () -> deps#billing_fetch acc))
