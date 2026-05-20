open Effet

let program (services : #Dx_common.services) =
  Bag_m17.program services
  |> Effect.bind (fun acc -> Effect.sync "notify_fetch" (fun _ -> services#notify_fetch acc))

