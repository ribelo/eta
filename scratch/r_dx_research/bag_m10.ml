open Effet

let program (services : #Dx_common.services) =
  Bag_m09.program services
  |> Effect.bind (fun acc -> Effect.sync "audit_run" (fun _ -> services#audit_run acc))
  |> Effect.bind (fun acc -> Effect.sync "audit_fetch" (fun _ -> services#audit_fetch acc))

