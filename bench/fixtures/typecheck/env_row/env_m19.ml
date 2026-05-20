open Effet

let program () =
  Env_m18.program ()
  |> Effect.bind (fun acc -> Effect.thunk "feature_query" (fun env -> env#feature_query acc))
