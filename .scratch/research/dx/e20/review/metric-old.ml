open Eta

let tenant_meter (sink : Capabilities.meter) : Capabilities.meter =
  object
    method record (point : Capabilities.metric_point) =
      sink#record { point with attrs = point.attrs @ [ ("tenant", "acme") ] }
  end

let request =
  Effect.metric_counter ~name:"requests" ~monotonic:true (Capabilities.Int 1)

(* Eta has no scoped meter override. To use this wrapper, runtime construction
   must install [tenant_meter sink], which affects that runtime rather than one
   lexical request/tenant subtree. *)
