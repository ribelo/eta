open Effet

let program (services : #Dx_common.services) =
  Bag_m16.program services
  |> Effect.bind (fun acc -> Effect.sync "notify_run" (fun _ -> services#notify_run acc))

