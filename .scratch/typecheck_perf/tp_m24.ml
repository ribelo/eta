open Effet

let program () =
  Tp_m23.program ()
  |> Effect.bind (fun acc -> Effect.thunk "m24.rate_limit" (fun env -> env#rate_limit acc))
  |> Effect.bind (fun acc -> if false then Effect.fail (`Validation "m24") else Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.thunk "m24.clock_now" (fun env -> env#clock_now acc) |> Effect.annotate ~key:"module" ~value:"24" |> Effect.named "m24.named")
  |> Effect.bind (fun acc -> Effect.par (Effect.thunk "m24.left" (fun env -> env#user_read acc)) (Effect.thunk "m24.right" (fun env -> env#user_write acc)) |> Effect.map (fun (a, b) -> a + b))
  |> Effect.bind (fun acc -> Effect.all [ Effect.pure acc; Effect.thunk "m24.all1" (fun env -> env#order_read acc); Effect.thunk "m24.all2" (fun env -> env#order_write acc) ] |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.all_settled [ Effect.pure acc; Effect.fail (`Cache "m24"); Effect.pure (acc + 1) ] |> Effect.map (List.fold_left (fun n -> function Ok v -> n + v | Error _ -> n) 0))
  |> Effect.bind (fun acc -> Effect.for_each_par_bounded ~max:2 [ acc; acc + 1; acc + 2 ] (fun n -> Effect.thunk "m24.each" (fun env -> env#billing_charge n)) |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.race [ Effect.pure acc; Effect.pure (acc + 1) ])
  |> Effect.bind (fun acc -> Effect.retry Tp_common.schedule (function `External _ -> true | _ -> false) (Effect.pure acc))
  |> Effect.bind (fun acc -> Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.scoped (Effect.acquire_release ~acquire:(Effect.pure acc) ~release:(fun _ -> Effect.thunk "m24.release" (fun _ -> ())) |> Effect.map (fun v -> v + 1)))
  |> Effect.bind (fun acc -> Supervisor.scoped { run = fun sup -> let open Supervisor.Scope in let* child = start sup (lift (Effect.pure (acc + 24))) in await child })
