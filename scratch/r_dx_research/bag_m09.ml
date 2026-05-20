open Effet

let program (services : #Dx_common.services) =
  Bag_m08.program services
  |> Effect.bind (fun acc -> Effect.sync "audit_query" (fun _ -> services#audit_query acc))
  |> Effect.bind (fun acc -> Effect.sync "audit_get" (fun _ -> services#audit_get acc))

