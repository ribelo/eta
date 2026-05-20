open Effet

let program (services : #Dx_common.services) =
  Effect.pure 0
  |> Effect.bind (fun acc -> Effect.sync "user_query" (fun _ -> services#user_query acc))
  |> Effect.bind (fun acc -> Effect.sync "user_get" (fun _ -> services#user_get acc))

