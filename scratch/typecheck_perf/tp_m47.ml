open Effet

let program () =
  Tp_m46.program ()
  |> Effect.bind (fun acc -> Effect.thunk "m47.policy_eval" (fun env -> env#policy_eval acc))
  |> Effect.bind (fun acc -> if false then Effect.fail (`Validation "m47") else Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.thunk "m47.tenant_lookup" (fun env -> env#tenant_lookup acc) |> Effect.annotate ~key:"module" ~value:"47" |> Effect.named "m47.named")
  |> Effect.bind (fun acc -> Effect.par (Effect.thunk "m47.left" (fun env -> env#rate_limit acc)) (Effect.thunk "m47.right" (fun env -> env#clock_now acc)) |> Effect.map (fun (a, b) -> a + b))
  |> Effect.bind (fun acc -> Effect.all [ Effect.pure acc; Effect.thunk "m47.all1" (fun env -> env#user_read acc); Effect.thunk "m47.all2" (fun env -> env#user_write acc) ] |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.all_settled [ Effect.pure acc; Effect.fail (`Cache "m47"); Effect.pure (acc + 1) ] |> Effect.map (List.fold_left (fun n -> function Ok v -> n + v | Error _ -> n) 0))
  |> Effect.bind (fun acc -> Effect.for_each_par_bounded ~max:2 [ acc; acc + 1; acc + 2 ] (fun n -> Effect.thunk "m47.each" (fun env -> env#order_read n)) |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.race [ Effect.pure acc; Effect.pure (acc + 1) ])
  |> Effect.bind (fun acc -> Effect.retry Tp_common.schedule (function `External _ -> true | _ -> false) (Effect.pure acc))
  |> Effect.bind (fun acc -> Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.scoped (Effect.acquire_release ~acquire:(Effect.pure acc) ~release:(fun _ -> Effect.thunk "m47.release" (fun _ -> ())) |> Effect.map (fun v -> v + 1)))
  |> Effect.bind (fun acc -> Supervisor.scoped { run = fun sup -> let open Supervisor.Scope in let* child = start sup (lift (Effect.pure (acc + 47))) in await child })
