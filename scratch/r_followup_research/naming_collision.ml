open Effet

let user_by_generic_query =
  Effect.sync "user.generic_query" (fun env -> env#query "current-user")

let order_by_generic_query =
  Effect.sync "order.generic_query" (fun env -> env#query "current-order")

let generic_composed =
  Effect.bind
    (fun user ->
       Effect.bind (fun order -> Effect.pure (user, order)) order_by_generic_query)
    user_by_generic_query

let user_by_namespaced_query =
  Effect.sync "user.namespaced_query" (fun env -> env#user_query "current")

let order_by_namespaced_query =
  Effect.sync "order.namespaced_query" (fun env -> env#order_query "current")

let namespaced_composed =
  Effect.bind
    (fun user ->
       Effect.bind (fun order -> Effect.pure (user, order)) order_by_namespaced_query)
    user_by_namespaced_query

let run_generic_collision () =
  let env =
    object
      method query key = "shared:" ^ key
    end
  in
  Services.run_with_env env generic_composed

let run_namespaced () =
  let env =
    object
      method user_query key = "user:" ^ key
      method order_query key = "order:" ^ key
    end
  in
  Services.run_with_env env namespaced_composed
