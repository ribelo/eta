open Eta

let program deps =
  Deps_m03.program deps
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#order_run acc))
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#order_fetch acc))
