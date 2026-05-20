open Effet

let program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get ~order_run ~order_fetch ~cache_query ~cache_get ~cache_run ~cache_fetch =
  Args_m05.program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get ~order_run ~order_fetch ~cache_query ~cache_get
  |> Effect.bind (fun acc -> Effect.sync "cache_run" (fun _ -> cache_run acc))
  |> Effect.bind (fun acc -> Effect.sync "cache_fetch" (fun _ -> cache_fetch acc))

