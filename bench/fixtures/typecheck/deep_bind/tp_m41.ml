open Eta

let program services =
  Tp_m40.program services
  |> Effect.bind (fun acc -> Effect.sync "m41.session_get" (fun () -> services#session_get acc))
  |> Effect.bind (fun acc -> if false then Effect.fail (`Validation "m41") else Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.sync "m41.inventory_get" (fun () -> services#inventory_get acc) |> Effect.annotate ~key:"module" ~value:"41" |> Effect.named "m41.named")
  |> Effect.bind (fun acc -> Effect.par (Effect.sync "m41.left" (fun () -> services#shipment_quote acc)) (Effect.sync "m41.right" (fun () -> services#email_send acc)) |> Effect.map (fun (a, b) -> a + b))
  |> Effect.bind (fun acc -> Effect.all [ Effect.pure acc; Effect.sync "m41.all1" (fun () -> services#sms_send acc); Effect.sync "m41.all2" (fun () -> services#report_build acc) ] |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.all_settled [ Effect.pure acc; Effect.fail (`Cache "m41"); Effect.pure (acc + 1) ] |> Effect.map (List.fold_left (fun n -> function Ok v -> n + v | Error _ -> n) 0))
  |> Effect.bind (fun acc -> Effect.for_each_par_bounded ~max:2 [ acc; acc + 1; acc + 2 ] (fun n -> Effect.sync "m41.each" (fun () -> services#policy_eval n)) |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.race [ Effect.pure acc; Effect.pure (acc + 1) ])
  |> Effect.bind (fun acc -> Effect.retry Tp_common.schedule (function `External _ -> true | _ -> false) (Effect.pure acc))
  |> Effect.bind (fun acc -> Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.scoped (Effect.acquire_release ~acquire:(Effect.pure acc) ~release:(fun _ -> Effect.sync "m41.release" (fun () -> ())) |> Effect.map (fun v -> v + 1)))
  |> Effect.bind (fun acc -> Supervisor.scoped { run = fun sup -> let open Supervisor.Scope in let* child = start sup (lift (Effect.pure (acc + 41))) in await child })
