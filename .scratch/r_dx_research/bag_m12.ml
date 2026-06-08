open Effet

let program (services : #Dx_common.services) =
  Bag_m11.program services
  |> Effect.bind (fun acc -> Effect.named "search_get" (Effect.sync (fun _ -> services#search_get acc)))

