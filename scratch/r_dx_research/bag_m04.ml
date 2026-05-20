open Effet

let program (services : #Dx_common.services) =
  Bag_m03.program services
  |> Effect.bind (fun acc -> Effect.sync "order_run" (fun _ -> services#order_run acc))
  |> Effect.bind (fun acc -> Effect.sync "order_fetch" (fun _ -> services#order_fetch acc))

