open Effet

let program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get ~order_run ~order_fetch ~cache_query ~cache_get =
  Args_m04.program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get ~order_run ~order_fetch
  |> Effect.bind (fun acc -> Effect.named "cache_query" (Effect.sync (fun _ -> cache_query acc)))
  |> Effect.bind (fun acc -> Effect.named "cache_get" (Effect.sync (fun _ -> cache_get acc)))

