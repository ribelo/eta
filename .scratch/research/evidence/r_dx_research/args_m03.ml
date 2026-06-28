open Effet

let program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get =
  Args_m02.program ~user_query ~user_get ~user_run ~user_fetch
  |> Effect.bind (fun acc -> Effect.named "order_query" (Effect.sync (fun _ -> order_query acc)))
  |> Effect.bind (fun acc -> Effect.named "order_get" (Effect.sync (fun _ -> order_get acc)))
