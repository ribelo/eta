open Effet

let program (services : #Dx_common.services) =
  Bag_m16.program services
  |> Effect.bind (fun acc -> Effect.named "notify_run" (Effect.sync (fun _ -> services#notify_run acc)))
