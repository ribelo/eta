open Effet

let program (services : #Dx_common.services) =
  Bag_m07.program services
  |> Effect.bind (fun acc -> Effect.sync "billing_run" (fun _ -> services#billing_run acc))
  |> Effect.bind (fun acc -> Effect.sync "billing_fetch" (fun _ -> services#billing_fetch acc))

