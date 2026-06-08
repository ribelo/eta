open Effet

let program (services : #Dx_common.services) =
  Bag_m10.program services
  |> Effect.bind (fun acc -> Effect.named "search_query" (Effect.sync (fun _ -> services#search_query acc)))

