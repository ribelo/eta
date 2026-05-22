open Eta

let program () =
  Tp_m35.program ()
  |> Effect.bind (fun acc -> Effect.sync "m36.notify_send" (fun env -> env#notify_send acc))
  |> Effect.bind (fun acc -> if false then Effect.fail (`Validation "m36") else Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.sync "m36.feature_flag" (fun env -> env#feature_flag acc) |> Effect.annotate ~key:"module" ~value:"36" |> Effect.named "m36.named")
  |> Effect.bind (fun acc -> Effect.par (Effect.sync "m36.left" (fun env -> env#config_get acc)) (Effect.sync "m36.right" (fun env -> env#metrics_count acc)) |> Effect.map (fun (a, b) -> a + b))
  |> Effect.bind (fun acc -> Effect.all [ Effect.pure acc; Effect.sync "m36.all1" (fun env -> env#auth_check acc); Effect.sync "m36.all2" (fun env -> env#session_get acc) ] |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.all_settled [ Effect.pure acc; Effect.fail (`Cache "m36"); Effect.pure (acc + 1) ] |> Effect.map (List.fold_left (fun n -> function Ok v -> n + v | Error _ -> n) 0))
  |> Effect.bind (fun acc -> Effect.for_each_par_bounded ~max:2 [ acc; acc + 1; acc + 2 ] (fun n -> Effect.sync "m36.each" (fun env -> env#inventory_get n)) |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.race [ Effect.pure acc; Effect.pure (acc + 1) ])
  |> Effect.bind (fun acc -> Effect.retry Tp_common.schedule (function `External _ -> true | _ -> false) (Effect.pure acc))
  |> Effect.bind (fun acc -> Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.scoped (Effect.acquire_release ~acquire:(Effect.pure acc) ~release:(fun _ -> Effect.sync "m36.release" (fun _ -> ())) |> Effect.map (fun v -> v + 1)))
  |> Effect.bind (fun acc -> Supervisor.scoped { run = fun sup -> let open Supervisor.Scope in let* child = start sup (lift (Effect.pure (acc + 36))) in await child })
