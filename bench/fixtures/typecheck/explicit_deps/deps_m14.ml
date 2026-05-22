open Eta

let program deps =
  Deps_m13.program deps
  |> Effect.bind (fun acc -> Effect.sync "search_fetch" (fun () -> deps#search_fetch acc))
