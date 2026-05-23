open Eta

let program deps =
  Deps_m04.program deps
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#cache_query acc))
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#cache_get acc))
