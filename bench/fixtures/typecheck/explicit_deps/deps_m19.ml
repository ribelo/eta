open Eta

let program deps =
  Deps_m18.program deps
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#feature_query acc))
