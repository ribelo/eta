open Effet

let program (services : #Dx_common.services) =
  Bag_m09.program services
  |> Effect.bind (fun acc -> Effect.named "audit_run" (Effect.sync (fun _ -> services#audit_run acc)))
  |> Effect.bind (fun acc -> Effect.named "audit_fetch" (Effect.sync (fun _ -> services#audit_fetch acc)))
