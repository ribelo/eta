open Effet

let program (services : #Dx_common.services) =
  Bag_m06.program services
  |> Effect.bind (fun acc -> Effect.sync "billing_query" (fun _ -> services#billing_query acc))
  |> Effect.bind (fun acc -> Effect.sync "billing_get" (fun _ -> services#billing_get acc))

