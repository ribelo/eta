open Effet

let program ~user_query ~user_get =
  Effect.pure 0
  |> Effect.bind (fun acc -> Effect.named "user_query" (Effect.sync (fun _ -> user_query acc)))
  |> Effect.bind (fun acc -> Effect.named "user_get" (Effect.sync (fun _ -> user_get acc)))

