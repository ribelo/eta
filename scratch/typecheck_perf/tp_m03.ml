open Effet

let program () =
  Tp_m02.program ()
  |> Effect.bind (fun acc -> Effect.thunk "m03.order_read" (fun env -> env#order_read acc))
  |> Effect.bind (fun acc -> if false then Effect.fail (`Validation "m03") else Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.thunk "m03.order_write" (fun env -> env#order_write acc) |> Effect.annotate ~key:"module" ~value:"03" |> Effect.named "m03.named")
  |> Effect.bind (fun acc -> Effect.par (Effect.thunk "m03.left" (fun env -> env#billing_charge acc)) (Effect.thunk "m03.right" (fun env -> env#billing_refund acc)) |> Effect.map (fun (a, b) -> a + b))
  |> Effect.bind (fun acc -> Effect.all [ Effect.pure acc; Effect.thunk "m03.all1" (fun env -> env#audit_log acc); Effect.thunk "m03.all2" (fun env -> env#cache_get acc) ] |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.all_settled [ Effect.pure acc; Effect.fail (`Cache "m03"); Effect.pure (acc + 1) ] |> Effect.map (List.fold_left (fun n -> function Ok v -> n + v | Error _ -> n) 0))
  |> Effect.bind (fun acc -> Effect.for_each_par_bounded ~max:2 [ acc; acc + 1; acc + 2 ] (fun n -> Effect.thunk "m03.each" (fun env -> env#cache_set n)) |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.race [ Effect.pure acc; Effect.pure (acc + 1) ])
  |> Effect.bind (fun acc -> Effect.retry Tp_common.schedule (function `External _ -> true | _ -> false) (Effect.pure acc))
  |> Effect.bind (fun acc -> Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.scoped (Effect.acquire_release ~acquire:(Effect.pure acc) ~release:(fun _ -> Effect.thunk "m03.release" (fun _ -> ())) |> Effect.map (fun v -> v + 1)))
  |> Effect.bind (fun acc -> Supervisor.scoped { run = fun sup -> let open Supervisor.Scope in let* child = start sup (lift (Effect.pure (acc + 3))) in await child })
