open Effet

let program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get ~order_run ~order_fetch =
  Args_m03.program ~user_query ~user_get ~user_run ~user_fetch ~order_query ~order_get
  |> Effect.bind (fun acc -> Effect.sync "order_run" (fun _ -> order_run acc))
  |> Effect.bind (fun acc -> Effect.sync "order_fetch" (fun _ -> order_fetch acc))

