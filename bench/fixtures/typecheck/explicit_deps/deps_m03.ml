open Eta

let program deps =
  Deps_m02.program deps
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#order_query acc))
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#order_get acc))
