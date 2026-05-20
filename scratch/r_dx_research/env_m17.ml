open Effet

let program () =
  Env_m16.program ()
  |> Effect.bind (fun acc -> Effect.sync "notify_run" (fun env -> env#notify_run acc))

