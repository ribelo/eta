open Effet

let program (services : #Dx_common.services) =
  Bag_m07.program services
  |> Effect.bind (fun acc -> Effect.named "billing_run" (Effect.sync (fun _ -> services#billing_run acc)))
  |> Effect.bind (fun acc -> Effect.named "billing_fetch" (Effect.sync (fun _ -> services#billing_fetch acc)))

