open Effet

let program (services : #Dx_common.services) =
  Bag_m12.program services
  |> Effect.bind (fun acc -> Effect.sync "search_run" (fun _ -> services#search_run acc))

