open Eta

let program deps =
  Deps_m19.program deps
  |> Effect.bind (fun acc -> Effect.sync "feature_get" (fun () -> deps#feature_get acc))
