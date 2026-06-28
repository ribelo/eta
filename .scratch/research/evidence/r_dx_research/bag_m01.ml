open Effet

let program (services : #Dx_common.services) =
  Effect.pure 0
  |> Effect.bind (fun acc -> Effect.named "user_query" (Effect.sync (fun _ -> services#user_query acc)))
  |> Effect.bind (fun acc -> Effect.named "user_get" (Effect.sync (fun _ -> services#user_get acc)))
