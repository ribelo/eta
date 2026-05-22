open Effet

let program (services : #Dx_common.services) =
  Bag_m14.program services
  |> Effect.bind (fun acc -> Effect.named "notify_query" (Effect.sync (fun _ -> services#notify_query acc)))

