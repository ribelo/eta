open Effet

let program (services : #Dx_common.services) =
  Bag_m02.program services
  |> Effect.bind (fun acc -> Effect.named "order_query" (Effect.sync (fun _ -> services#order_query acc)))
  |> Effect.bind (fun acc -> Effect.named "order_get" (Effect.sync (fun _ -> services#order_get acc)))
