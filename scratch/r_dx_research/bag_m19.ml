open Effet

let program (services : #Dx_common.services) =
  Bag_m18.program services
  |> Effect.bind (fun acc -> Effect.sync "feature_query" (fun _ -> services#feature_query acc))

