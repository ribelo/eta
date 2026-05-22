open Eta

let program deps =
  Deps_m14.program deps
  |> Effect.bind (fun acc -> Effect.sync "notify_query" (fun () -> deps#notify_query acc))
