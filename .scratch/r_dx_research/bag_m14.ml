open Effet

let program (services : #Dx_common.services) =
  Bag_m13.program services
  |> Effect.bind (fun acc -> Effect.named "search_fetch" (Effect.sync (fun _ -> services#search_fetch acc)))

