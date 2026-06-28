open Effet

let program () =
  Env_m18.program ()
  |> Effect.bind (fun acc -> Effect.named "feature_query" (Effect.sync (fun env -> env#feature_query acc)))
