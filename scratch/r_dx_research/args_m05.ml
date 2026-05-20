open Effet

let program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get ~order_run ~order_fetch ~cache_query ~cache_get =
  Args_m04.program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get ~order_run ~order_fetch
  |> Effect.bind (fun acc -> Effect.sync "cache_query" (fun _ -> cache_query acc))
  |> Effect.bind (fun acc -> Effect.sync "cache_get" (fun _ -> cache_get acc))

