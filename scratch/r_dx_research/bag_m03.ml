open Effet

let program (services : #Dx_common.services) =
  Bag_m02.program services
  |> Effect.bind (fun acc -> Effect.sync "order_query" (fun _ -> services#order_query acc))
  |> Effect.bind (fun acc -> Effect.sync "order_get" (fun _ -> services#order_get acc))

