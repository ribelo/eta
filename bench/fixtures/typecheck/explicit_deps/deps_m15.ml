open Eta

let program deps =
  Deps_m14.program deps
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#notify_query acc))
