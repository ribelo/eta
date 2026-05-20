open Effet

let program () =
  Env_m17.program ()
  |> Effect.bind (fun acc -> Effect.sync "notify_fetch" (fun env -> env#notify_fetch acc))

