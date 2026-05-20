open Effet

let program (services : #Dx_common.services) =
  Bag_m15.program services
  |> Effect.bind (fun acc -> Effect.sync "notify_get" (fun _ -> services#notify_get acc))

