open Effet

let program () =
  Env_m19.program ()
  |> Effect.bind (fun acc -> Effect.sync "feature_get" (fun env -> env#feature_get acc))

