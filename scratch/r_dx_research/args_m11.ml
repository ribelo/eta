open Effet

let program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get ~order_run ~order_fetch ~cache_query ~cache_get ~cache_run ~cache_fetch ~billing_query ~billing_get ~billing_run ~billing_fetch ~audit_query ~audit_get ~audit_run ~audit_fetch ~search_query =
  Args_m10.program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get ~order_run ~order_fetch ~cache_query ~cache_get ~cache_run ~cache_fetch ~billing_query ~billing_get ~billing_run ~billing_fetch ~audit_query ~audit_get ~audit_run ~audit_fetch
  |> Effect.bind (fun acc -> Effect.sync "search_query" (fun _ -> search_query acc))

