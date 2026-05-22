open Eta

let program deps =
  Deps_m04.program deps
  |> Effect.bind (fun acc -> Effect.sync "cache_query" (fun () -> deps#cache_query acc))
  |> Effect.bind (fun acc -> Effect.sync "cache_get" (fun () -> deps#cache_get acc))
