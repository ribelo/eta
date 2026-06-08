open Effet

let a = Effect.named "query-int" (Effect.sync (fun env -> env#query 1))
let b = Effect.named "query-string" (Effect.sync (fun env -> env#query "x"))
let c = Effect.named "get-int" (Effect.sync (fun env -> env#get 1))
let d = Effect.named "get-string" (Effect.sync (fun env -> env#get "x"))
let _bad =
  a |> Effect.bind (fun _ -> b)
    |> Effect.bind (fun _ -> c)
    |> Effect.bind (fun _ -> d)
