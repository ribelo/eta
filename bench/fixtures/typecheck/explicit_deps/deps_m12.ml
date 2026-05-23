open Eta

let program deps =
  Deps_m11.program deps
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#search_get acc))
