open Eta

let program deps =
  Deps_m01.program deps
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#user_run acc))
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#user_fetch acc))
