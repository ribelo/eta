open Eta

let program deps =
  Deps_m10.program deps
  |> Effect.bind (fun acc -> Effect.sync "search_query" (fun () -> deps#search_query acc))
