open Effet

let program () =
  Tp_m10.program ()
  |> Effect.bind (fun acc -> Effect.thunk "m11.notify_send" (fun env -> env#notify_send acc))
  |> Effect.bind (fun acc -> if false then Effect.fail (`Validation "m11") else Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.thunk "m11.feature_flag" (fun env -> env#feature_flag acc) |> Effect.annotate ~key:"module" ~value:"11" |> Effect.named "m11.named")
  |> Effect.bind (fun acc -> Effect.par (Effect.thunk "m11.left" (fun env -> env#config_get acc)) (Effect.thunk "m11.right" (fun env -> env#metrics_count acc)) |> Effect.map (fun (a, b) -> a + b))
  |> Effect.bind (fun acc -> Effect.all [ Effect.pure acc; Effect.thunk "m11.all1" (fun env -> env#auth_check acc); Effect.thunk "m11.all2" (fun env -> env#session_get acc) ] |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.all_settled [ Effect.pure acc; Effect.fail (`Cache "m11"); Effect.pure (acc + 1) ] |> Effect.map (List.fold_left (fun n -> function Ok v -> n + v | Error _ -> n) 0))
  |> Effect.bind (fun acc -> Effect.for_each_par_bounded ~max:2 [ acc; acc + 1; acc + 2 ] (fun n -> Effect.thunk "m11.each" (fun env -> env#inventory_get n)) |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.race [ Effect.pure acc; Effect.pure (acc + 1) ])
  |> Effect.bind (fun acc -> Effect.retry Tp_common.schedule (function `External _ -> true | _ -> false) (Effect.pure acc))
  |> Effect.bind (fun acc -> Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.scoped (Effect.acquire_release ~acquire:(Effect.pure acc) ~release:(fun _ -> Effect.thunk "m11.release" (fun _ -> ())) |> Effect.map (fun v -> v + 1)))
  |> Effect.bind (fun acc -> Supervisor.scoped { run = fun sup -> let open Supervisor.Scope in let* child = start sup (lift (Effect.pure (acc + 11))) in await child })
