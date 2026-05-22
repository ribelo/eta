open Eta

let program () =
  Tp_m14.program ()
  |> Effect.bind (fun acc -> Effect.sync "m15.auth_check" (fun env -> env#auth_check acc))
  |> Effect.bind (fun acc -> if false then Effect.fail (`Validation "m15") else Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.sync "m15.session_get" (fun env -> env#session_get acc) |> Effect.annotate ~key:"module" ~value:"15" |> Effect.named "m15.named")
  |> Effect.bind (fun acc -> Effect.par (Effect.sync "m15.left" (fun env -> env#inventory_get acc)) (Effect.sync "m15.right" (fun env -> env#shipment_quote acc)) |> Effect.map (fun (a, b) -> a + b))
  |> Effect.bind (fun acc -> Effect.all [ Effect.pure acc; Effect.sync "m15.all1" (fun env -> env#email_send acc); Effect.sync "m15.all2" (fun env -> env#sms_send acc) ] |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.all_settled [ Effect.pure acc; Effect.fail (`Cache "m15"); Effect.pure (acc + 1) ] |> Effect.map (List.fold_left (fun n -> function Ok v -> n + v | Error _ -> n) 0))
  |> Effect.bind (fun acc -> Effect.for_each_par_bounded ~max:2 [ acc; acc + 1; acc + 2 ] (fun n -> Effect.sync "m15.each" (fun env -> env#report_build n)) |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.race [ Effect.pure acc; Effect.pure (acc + 1) ])
  |> Effect.bind (fun acc -> Effect.retry Tp_common.schedule (function `External _ -> true | _ -> false) (Effect.pure acc))
  |> Effect.bind (fun acc -> Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.scoped (Effect.acquire_release ~acquire:(Effect.pure acc) ~release:(fun _ -> Effect.sync "m15.release" (fun _ -> ())) |> Effect.map (fun v -> v + 1)))
  |> Effect.bind (fun acc -> Supervisor.scoped { run = fun sup -> let open Supervisor.Scope in let* child = start sup (lift (Effect.pure (acc + 15))) in await child })
