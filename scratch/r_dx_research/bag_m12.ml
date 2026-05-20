open Effet

let program (services : #Dx_common.services) =
  Bag_m11.program services
  |> Effect.bind (fun acc -> Effect.sync "search_get" (fun _ -> services#search_get acc))

