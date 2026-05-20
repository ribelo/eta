open Effet

let program () =
  Env_m15.program ()
  |> Effect.bind (fun acc -> Effect.thunk "notify_get" (fun env -> env#notify_get acc))
