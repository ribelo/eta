open Effet

let program () =
  Env_m19.program ()
  |> Effect.bind (fun acc -> Effect.named "feature_get" (Effect.sync (fun env -> env#feature_get acc)))

