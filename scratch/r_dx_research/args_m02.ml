open Effet

let program ~user_query ~user_get ~user_run ~user_fetch =
  Args_m01.program ~user_query ~user_get
  |> Effect.bind (fun acc -> Effect.sync "user_run" (fun _ -> user_run acc))
  |> Effect.bind (fun acc -> Effect.sync "user_fetch" (fun _ -> user_fetch acc))

