open Eta

let program deps =
  Deps_m02.program deps
  |> Effect.bind (fun acc -> Effect.sync "order_query" (fun () -> deps#order_query acc))
  |> Effect.bind (fun acc -> Effect.sync "order_get" (fun () -> deps#order_get acc))
