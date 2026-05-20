open Effet

let program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get ~order_run ~order_fetch ~cache_query ~cache_get ~cache_run ~cache_fetch ~billing_query ~billing_get ~billing_run ~billing_fetch =
  Args_m07.program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get ~order_run ~order_fetch ~cache_query ~cache_get ~cache_run ~cache_fetch ~billing_query ~billing_get
  |> Effect.bind (fun acc -> Effect.sync "billing_run" (fun _ -> billing_run acc))
  |> Effect.bind (fun acc -> Effect.sync "billing_fetch" (fun _ -> billing_fetch acc))

