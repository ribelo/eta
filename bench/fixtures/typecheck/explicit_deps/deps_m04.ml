open Eta

let program deps =
  Deps_m03.program deps
  |> Effect.bind (fun acc -> Effect.sync "order_run" (fun () -> deps#order_run acc))
  |> Effect.bind (fun acc -> Effect.sync "order_fetch" (fun () -> deps#order_fetch acc))
