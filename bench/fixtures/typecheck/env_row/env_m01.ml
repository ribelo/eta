open Eta

let program () =
  Effect.pure 0
  |> Effect.bind (fun acc -> Effect.sync "user_query" (fun env -> env#user_query acc))
  |> Effect.bind (fun acc -> Effect.sync "user_get" (fun env -> env#user_get acc))
