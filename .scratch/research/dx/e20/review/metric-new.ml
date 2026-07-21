open Eta

let tenant_acme (point : Capabilities.metric_point) =
  Effect.Replace { point with attrs = point.attrs @ [ ("tenant", "acme") ] }

let request =
  Effect.metric_counter ~name:"requests" ~monotonic:true (Capabilities.Int 1)
  |> Effect.intercept_metric tenant_acme

(* The existing runtime meter remains installed; only points emitted in this
   lexical subtree receive the tenant label. *)
