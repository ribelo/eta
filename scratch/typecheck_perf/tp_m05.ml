open Effet

let program () =
  Tp_m04.program ()
  |> Effect.bind (fun acc -> Effect.thunk "m05.billing_charge" (fun env -> env#billing_charge acc))
  |> Effect.bind (fun acc -> if false then Effect.fail (`Validation "m05") else Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.thunk "m05.billing_refund" (fun env -> env#billing_refund acc) |> Effect.annotate ~key:"module" ~value:"05" |> Effect.named "m05.named")
  |> Effect.bind (fun acc -> Effect.par (Effect.thunk "m05.left" (fun env -> env#audit_log acc)) (Effect.thunk "m05.right" (fun env -> env#cache_get acc)) |> Effect.map (fun (a, b) -> a + b))
  |> Effect.bind (fun acc -> Effect.all [ Effect.pure acc; Effect.thunk "m05.all1" (fun env -> env#cache_set acc); Effect.thunk "m05.all2" (fun env -> env#search_query acc) ] |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.all_settled [ Effect.pure acc; Effect.fail (`Cache "m05"); Effect.pure (acc + 1) ] |> Effect.map (List.fold_left (fun n -> function Ok v -> n + v | Error _ -> n) 0))
  |> Effect.bind (fun acc -> Effect.for_each_par_bounded ~max:2 [ acc; acc + 1; acc + 2 ] (fun n -> Effect.thunk "m05.each" (fun env -> env#notify_send n)) |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.race [ Effect.pure acc; Effect.pure (acc + 1) ])
  |> Effect.bind (fun acc -> Effect.retry Tp_common.schedule (function `External _ -> true | _ -> false) (Effect.pure acc))
  |> Effect.bind (fun acc -> Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.scoped (Effect.acquire_release ~acquire:(Effect.pure acc) ~release:(fun _ -> Effect.thunk "m05.release" (fun _ -> ())) |> Effect.map (fun v -> v + 1)))
  |> Effect.bind (fun acc -> Supervisor.scoped { run = fun sup -> let open Supervisor.Scope in let* child = start sup (lift (Effect.pure (acc + 5))) in await child })
