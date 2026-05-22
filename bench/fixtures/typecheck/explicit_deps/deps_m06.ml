open Eta

let program deps =
  Deps_m05.program deps
  |> Effect.bind (fun acc -> Effect.sync "cache_run" (fun () -> deps#cache_run acc))
  |> Effect.bind (fun acc -> Effect.sync "cache_fetch" (fun () -> deps#cache_fetch acc))
