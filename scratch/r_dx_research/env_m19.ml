open Effet

let program () =
  Env_m18.program ()
  |> Effect.bind (fun acc -> Effect.sync "feature_query" (fun env -> env#feature_query acc))

