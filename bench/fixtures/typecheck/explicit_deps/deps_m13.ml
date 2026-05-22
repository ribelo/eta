open Eta

let program deps =
  Deps_m12.program deps
  |> Effect.bind (fun acc -> Effect.sync "search_run" (fun () -> deps#search_run acc))
