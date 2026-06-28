open Effet

let program (services : #Dx_common.services) =
  Bag_m06.program services
  |> Effect.bind (fun acc -> Effect.named "billing_query" (Effect.sync (fun _ -> services#billing_query acc)))
  |> Effect.bind (fun acc -> Effect.named "billing_get" (Effect.sync (fun _ -> services#billing_get acc)))
