open Effet

let program () =
  Tp_m42.program ()
  |> Effect.bind (fun acc -> Effect.thunk "m43.shipment_quote" (fun env -> env#shipment_quote acc))
  |> Effect.bind (fun acc -> if false then Effect.fail (`Validation "m43") else Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.thunk "m43.email_send" (fun env -> env#email_send acc) |> Effect.annotate ~key:"module" ~value:"43" |> Effect.named "m43.named")
  |> Effect.bind (fun acc -> Effect.par (Effect.thunk "m43.left" (fun env -> env#sms_send acc)) (Effect.thunk "m43.right" (fun env -> env#report_build acc)) |> Effect.map (fun (a, b) -> a + b))
  |> Effect.bind (fun acc -> Effect.all [ Effect.pure acc; Effect.thunk "m43.all1" (fun env -> env#policy_eval acc); Effect.thunk "m43.all2" (fun env -> env#tenant_lookup acc) ] |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.all_settled [ Effect.pure acc; Effect.fail (`Cache "m43"); Effect.pure (acc + 1) ] |> Effect.map (List.fold_left (fun n -> function Ok v -> n + v | Error _ -> n) 0))
  |> Effect.bind (fun acc -> Effect.for_each_par_bounded ~max:2 [ acc; acc + 1; acc + 2 ] (fun n -> Effect.thunk "m43.each" (fun env -> env#rate_limit n)) |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.race [ Effect.pure acc; Effect.pure (acc + 1) ])
  |> Effect.bind (fun acc -> Effect.retry Tp_common.schedule (function `External _ -> true | _ -> false) (Effect.pure acc))
  |> Effect.bind (fun acc -> Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.scoped (Effect.acquire_release ~acquire:(Effect.pure acc) ~release:(fun _ -> Effect.thunk "m43.release" (fun _ -> ())) |> Effect.map (fun v -> v + 1)))
  |> Effect.bind (fun acc -> Supervisor.scoped { run = fun sup -> let open Supervisor.Scope in let* child = start sup (lift (Effect.pure (acc + 43))) in await child })
