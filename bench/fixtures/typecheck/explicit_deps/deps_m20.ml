open Eta

let program deps =
  Deps_m19.program deps
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#feature_get acc))
