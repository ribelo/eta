open Effet

let program (services : #Dx_common.services) =
  Bag_m01.program services
  |> Effect.bind (fun acc -> Effect.sync "user_run" (fun _ -> services#user_run acc))
  |> Effect.bind (fun acc -> Effect.sync "user_fetch" (fun _ -> services#user_fetch acc))

