open Effet

let program () =
  Effect.pure 0
  |> Effect.bind (fun acc -> Effect.named "user_query" (Effect.sync (fun env -> env#user_query acc)))
  |> Effect.bind (fun acc -> Effect.named "user_get" (Effect.sync (fun env -> env#user_get acc)))

