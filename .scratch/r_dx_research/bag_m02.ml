open Effet

let program (services : #Dx_common.services) =
  Bag_m01.program services
  |> Effect.bind (fun acc -> Effect.named "user_run" (Effect.sync (fun _ -> services#user_run acc)))
  |> Effect.bind (fun acc -> Effect.named "user_fetch" (Effect.sync (fun _ -> services#user_fetch acc)))

