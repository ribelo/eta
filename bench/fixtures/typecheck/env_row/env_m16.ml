open Eta

let program () =
  Env_m15.program ()
  |> Effect.bind (fun acc -> Effect.sync "notify_get" (fun env -> env#notify_get acc))
