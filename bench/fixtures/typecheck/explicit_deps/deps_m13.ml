open Eta

let program deps =
  Deps_m12.program deps
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#search_run acc))
