open Effet

let program (services : #Dx_common.services) =
  Bag_m05.program services
  |> Effect.bind (fun acc -> Effect.sync "cache_run" (fun _ -> services#cache_run acc))
  |> Effect.bind (fun acc -> Effect.sync "cache_fetch" (fun _ -> services#cache_fetch acc))

