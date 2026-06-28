open Effet

let program (services : #Dx_common.services) =
  Bag_m15.program services
  |> Effect.bind (fun acc -> Effect.named "notify_get" (Effect.sync (fun _ -> services#notify_get acc)))
