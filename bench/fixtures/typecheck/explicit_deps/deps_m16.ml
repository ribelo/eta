open Eta

let program deps =
  Deps_m15.program deps
  |> Effect.bind (fun acc -> Effect.sync "notify_get" (fun () -> deps#notify_get acc))
