open Eta

let program deps =
  Deps_m17.program deps
  |> Effect.bind (fun acc -> Effect.sync "notify_fetch" (fun () -> deps#notify_fetch acc))
