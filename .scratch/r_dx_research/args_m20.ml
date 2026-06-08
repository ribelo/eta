open Effet

let program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get ~order_run ~order_fetch ~cache_query ~cache_get ~cache_run ~cache_fetch ~billing_query ~billing_get ~billing_run ~billing_fetch ~audit_query ~audit_get ~audit_run ~audit_fetch ~search_query ~search_get ~search_run ~search_fetch ~notify_query ~notify_get ~notify_run ~notify_fetch ~feature_query ~feature_get =
  Args_m19.program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get ~order_run ~order_fetch ~cache_query ~cache_get ~cache_run ~cache_fetch ~billing_query ~billing_get ~billing_run ~billing_fetch ~audit_query ~audit_get ~audit_run ~audit_fetch ~search_query ~search_get ~search_run ~search_fetch ~notify_query ~notify_get ~notify_run ~notify_fetch ~feature_query
  |> Effect.bind (fun acc -> Effect.named "feature_get" (Effect.sync (fun _ -> feature_get acc)))

