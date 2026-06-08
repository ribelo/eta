open Effet

let program (services : #Dx_common.services) =
  Bag_m05.program services
  |> Effect.bind (fun acc -> Effect.named "cache_run" (Effect.sync (fun _ -> services#cache_run acc)))
  |> Effect.bind (fun acc -> Effect.named "cache_fetch" (Effect.sync (fun _ -> services#cache_fetch acc)))

