open Effet

let program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get ~order_run ~order_fetch ~cache_query ~cache_get ~cache_run ~cache_fetch ~billing_query ~billing_get =
  Args_m06.program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get ~order_run ~order_fetch ~cache_query ~cache_get ~cache_run ~cache_fetch
  |> Effect.bind (fun acc -> Effect.sync "billing_query" (fun _ -> billing_query acc))
  |> Effect.bind (fun acc -> Effect.sync "billing_get" (fun _ -> billing_get acc))

