open Eta

let program deps =
  Deps_m16.program deps
  |> Effect.bind (fun acc -> Effect.sync "notify_run" (fun () -> deps#notify_run acc))
