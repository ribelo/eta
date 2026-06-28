open Effet

let program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get ~order_run ~order_fetch ~cache_query ~cache_get ~cache_run ~cache_fetch ~billing_query ~billing_get ~billing_run ~billing_fetch ~audit_query ~audit_get =
  Args_m08.program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get ~order_run ~order_fetch ~cache_query ~cache_get ~cache_run ~cache_fetch ~billing_query ~billing_get ~billing_run ~billing_fetch
  |> Effect.bind (fun acc -> Effect.named "audit_query" (Effect.sync (fun _ -> audit_query acc)))
  |> Effect.bind (fun acc -> Effect.named "audit_get" (Effect.sync (fun _ -> audit_get acc)))
