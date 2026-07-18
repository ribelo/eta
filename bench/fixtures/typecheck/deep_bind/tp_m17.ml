open Eta

let program services =
  Tp_m16.program services
  |> Effect.bind (fun acc -> Effect.sync (fun () -> services#inventory_get acc))
  |> Effect.bind (fun acc -> if false then Effect.fail (`Validation "m17") else Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.sync (fun () -> services#shipment_quote acc) |> Effect.annotate ~key:"module" ~value:"17" |> Effect.named "m17.named")
  |> Effect.bind (fun acc -> Effect.par (Effect.sync (fun () -> services#email_send acc)) (Effect.sync (fun () -> services#sms_send acc)) |> Effect.map (fun (a, b) -> a + b))
  |> Effect.bind (fun acc -> Effect.all [ Effect.pure acc; Effect.sync (fun () -> services#report_build acc); Effect.sync (fun () -> services#policy_eval acc) ] |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.all_settled [ Effect.pure acc; Effect.fail (`Cache "m17"); Effect.pure (acc + 1) ] |> Effect.map (List.fold_left (fun n -> function Ok v -> n + v | Error _ -> n) 0))
  |> Effect.bind (fun acc -> Effect.map_par ~max_concurrent:2 (fun n -> Effect.sync (fun () -> services#tenant_lookup n)) [ acc; acc + 1; acc + 2 ] |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.race [ Effect.pure acc; Effect.pure (acc + 1) ])
  |> Effect.bind (fun acc -> Effect.retry ~schedule:(Tp_common.schedule ()) ~while_:(function `External _ -> true | _ -> false) (Effect.pure acc))
  |> Effect.bind (fun acc -> Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.with_scope (Effect.acquire_release ~acquire:(Effect.pure acc) ~release:(fun _ -> Effect.sync (fun () -> ())) |> Effect.map (fun v -> v + 1)))
  |> Effect.bind (fun acc -> Supervisor.scoped { run = fun sup -> let open Supervisor.Scope in let* child = start sup (lift (Effect.pure (acc + 17))) in await child })
