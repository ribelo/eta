open Effet

let program (services : #Dx_common.services) =
  Bag_m04.program services
  |> Effect.bind (fun acc -> Effect.named "cache_query" (Effect.sync (fun _ -> services#cache_query acc)))
  |> Effect.bind (fun acc -> Effect.named "cache_get" (Effect.sync (fun _ -> services#cache_get acc)))
