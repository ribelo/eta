open Effet

let program (services : #Dx_common.services) =
  Bag_m17.program services
  |> Effect.bind (fun acc -> Effect.named "notify_fetch" (Effect.sync (fun _ -> services#notify_fetch acc)))
