open Effet

let program (services : #Dx_common.services) =
  Bag_m08.program services
  |> Effect.bind (fun acc -> Effect.named "audit_query" (Effect.sync (fun _ -> services#audit_query acc)))
  |> Effect.bind (fun acc -> Effect.named "audit_get" (Effect.sync (fun _ -> services#audit_get acc)))
