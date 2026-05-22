open Eta

let program () =
  Tp_m26.program ()
  |> Effect.bind (fun acc -> Effect.sync "m27.user_write" (fun env -> env#user_write acc))
  |> Effect.bind (fun acc -> if false then Effect.fail (`Validation "m27") else Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.sync "m27.order_read" (fun env -> env#order_read acc) |> Effect.annotate ~key:"module" ~value:"27" |> Effect.named "m27.named")
  |> Effect.bind (fun acc -> Effect.par (Effect.sync "m27.left" (fun env -> env#order_write acc)) (Effect.sync "m27.right" (fun env -> env#billing_charge acc)) |> Effect.map (fun (a, b) -> a + b))
  |> Effect.bind (fun acc -> Effect.all [ Effect.pure acc; Effect.sync "m27.all1" (fun env -> env#billing_refund acc); Effect.sync "m27.all2" (fun env -> env#audit_log acc) ] |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.all_settled [ Effect.pure acc; Effect.fail (`Cache "m27"); Effect.pure (acc + 1) ] |> Effect.map (List.fold_left (fun n -> function Ok v -> n + v | Error _ -> n) 0))
  |> Effect.bind (fun acc -> Effect.for_each_par_bounded ~max:2 [ acc; acc + 1; acc + 2 ] (fun n -> Effect.sync "m27.each" (fun env -> env#cache_get n)) |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.race [ Effect.pure acc; Effect.pure (acc + 1) ])
  |> Effect.bind (fun acc -> Effect.retry Tp_common.schedule (function `External _ -> true | _ -> false) (Effect.pure acc))
  |> Effect.bind (fun acc -> Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.scoped (Effect.acquire_release ~acquire:(Effect.pure acc) ~release:(fun _ -> Effect.sync "m27.release" (fun _ -> ())) |> Effect.map (fun v -> v + 1)))
  |> Effect.bind (fun acc -> Supervisor.scoped { run = fun sup -> let open Supervisor.Scope in let* child = start sup (lift (Effect.pure (acc + 27))) in await child })
