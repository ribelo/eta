open Effet

let program (services : #Dx_common.services) =
  Bag_m12.program services
  |> Effect.bind (fun acc -> Effect.named "search_run" (Effect.sync (fun _ -> services#search_run acc)))
