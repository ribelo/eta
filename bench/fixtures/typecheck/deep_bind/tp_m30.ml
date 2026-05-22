open Eta

let program services =
  Tp_m29.program services
  |> Effect.bind (fun acc -> Effect.sync "m30.billing_charge" (fun () -> services#billing_charge acc))
  |> Effect.bind (fun acc -> if false then Effect.fail (`Validation "m30") else Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.sync "m30.billing_refund" (fun () -> services#billing_refund acc) |> Effect.annotate ~key:"module" ~value:"30" |> Effect.named "m30.named")
  |> Effect.bind (fun acc -> Effect.par (Effect.sync "m30.left" (fun () -> services#audit_log acc)) (Effect.sync "m30.right" (fun () -> services#cache_get acc)) |> Effect.map (fun (a, b) -> a + b))
  |> Effect.bind (fun acc -> Effect.all [ Effect.pure acc; Effect.sync "m30.all1" (fun () -> services#cache_set acc); Effect.sync "m30.all2" (fun () -> services#search_query acc) ] |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.all_settled [ Effect.pure acc; Effect.fail (`Cache "m30"); Effect.pure (acc + 1) ] |> Effect.map (List.fold_left (fun n -> function Ok v -> n + v | Error _ -> n) 0))
  |> Effect.bind (fun acc -> Effect.for_each_par_bounded ~max:2 [ acc; acc + 1; acc + 2 ] (fun n -> Effect.sync "m30.each" (fun () -> services#notify_send n)) |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.race [ Effect.pure acc; Effect.pure (acc + 1) ])
  |> Effect.bind (fun acc -> Effect.retry Tp_common.schedule (function `External _ -> true | _ -> false) (Effect.pure acc))
  |> Effect.bind (fun acc -> Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.scoped (Effect.acquire_release ~acquire:(Effect.pure acc) ~release:(fun _ -> Effect.sync "m30.release" (fun () -> ())) |> Effect.map (fun v -> v + 1)))
  |> Effect.bind (fun acc -> Supervisor.scoped { run = fun sup -> let open Supervisor.Scope in let* child = start sup (lift (Effect.pure (acc + 30))) in await child })
