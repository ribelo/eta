open Effet

let program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get ~order_run ~order_fetch ~cache_query ~cache_get ~cache_run ~cache_fetch ~billing_query ~billing_get ~billing_run ~billing_fetch ~audit_query ~audit_get ~audit_run ~audit_fetch =
  Args_m09.program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get ~order_run ~order_fetch ~cache_query ~cache_get ~cache_run ~cache_fetch ~billing_query ~billing_get ~billing_run ~billing_fetch ~audit_query ~audit_get
  |> Effect.bind (fun acc -> Effect.sync "audit_run" (fun _ -> audit_run acc))
  |> Effect.bind (fun acc -> Effect.sync "audit_fetch" (fun _ -> audit_fetch acc))

