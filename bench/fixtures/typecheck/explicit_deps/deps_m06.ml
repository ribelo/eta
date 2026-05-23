open Eta

let program deps =
  Deps_m05.program deps
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#cache_run acc))
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#cache_fetch acc))
