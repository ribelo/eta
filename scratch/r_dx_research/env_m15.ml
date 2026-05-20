open Effet

let program () =
  Env_m14.program ()
  |> Effect.bind (fun acc -> Effect.sync "notify_query" (fun env -> env#notify_query acc))

