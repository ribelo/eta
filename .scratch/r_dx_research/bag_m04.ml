open Effet

let program (services : #Dx_common.services) =
  Bag_m03.program services
  |> Effect.bind (fun acc -> Effect.named "order_run" (Effect.sync (fun _ -> services#order_run acc)))
  |> Effect.bind (fun acc -> Effect.named "order_fetch" (Effect.sync (fun _ -> services#order_fetch acc)))

