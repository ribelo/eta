open Effet

let program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get ~order_run ~order_fetch ~cache_query ~cache_get ~cache_run ~cache_fetch ~billing_query ~billing_get ~billing_run ~billing_fetch ~audit_query ~audit_get ~audit_run ~audit_fetch ~search_query ~search_get ~search_run ~search_fetch ~notify_query ~notify_get ~notify_run =
  Args_m16.program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get ~order_run ~order_fetch ~cache_query ~cache_get ~cache_run ~cache_fetch ~billing_query ~billing_get ~billing_run ~billing_fetch ~audit_query ~audit_get ~audit_run ~audit_fetch ~search_query ~search_get ~search_run ~search_fetch ~notify_query ~notify_get
  |> Effect.bind (fun acc -> Effect.sync "notify_run" (fun _ -> notify_run acc))

