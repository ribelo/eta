open Effet

let program (services : #Dx_common.services) =
  Bag_m19.program services
  |> Effect.bind (fun acc -> Effect.named "feature_get" (Effect.sync (fun _ -> services#feature_get acc)))
