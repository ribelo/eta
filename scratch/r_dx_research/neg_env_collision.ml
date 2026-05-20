open Effet

let a = Effect.sync "query-int" (fun env -> env#query 1)
let b = Effect.sync "query-string" (fun env -> env#query "x")
let c = Effect.sync "get-int" (fun env -> env#get 1)
let d = Effect.sync "get-string" (fun env -> env#get "x")
let _bad =
  a |> Effect.bind (fun _ -> b)
    |> Effect.bind (fun _ -> c)
    |> Effect.bind (fun _ -> d)
