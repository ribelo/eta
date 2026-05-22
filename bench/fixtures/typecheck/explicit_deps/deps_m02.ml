open Eta

let program deps =
  Deps_m01.program deps
  |> Effect.bind (fun acc -> Effect.sync "user_run" (fun () -> deps#user_run acc))
  |> Effect.bind (fun acc -> Effect.sync "user_fetch" (fun () -> deps#user_fetch acc))
