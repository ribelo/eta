open Eta

let program deps =
  Effect.pure 0
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#user_query acc))
  |> Effect.bind (fun acc -> Effect.sync (fun () -> deps#user_get acc))
