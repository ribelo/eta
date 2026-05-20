open Effet

let program ~user_query ~user_get =
  Effect.pure 0
  |> Effect.bind (fun acc -> Effect.sync "user_query" (fun _ -> user_query acc))
  |> Effect.bind (fun acc -> Effect.sync "user_get" (fun _ -> user_get acc))

