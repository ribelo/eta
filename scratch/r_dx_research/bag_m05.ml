open Effet

let program (services : #Dx_common.services) =
  Bag_m04.program services
  |> Effect.bind (fun acc -> Effect.sync "cache_query" (fun _ -> services#cache_query acc))
  |> Effect.bind (fun acc -> Effect.sync "cache_get" (fun _ -> services#cache_get acc))

