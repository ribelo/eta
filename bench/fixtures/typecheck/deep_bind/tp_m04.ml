open Eta

let program services =
  Tp_m03.program services
  |> Effect.bind (fun acc -> Effect.sync "m04.order_write" (fun () -> services#order_write acc))
  |> Effect.bind (fun acc -> if false then Effect.fail (`Validation "m04") else Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.sync "m04.billing_charge" (fun () -> services#billing_charge acc) |> Effect.annotate ~key:"module" ~value:"04" |> Effect.named "m04.named")
  |> Effect.bind (fun acc -> Effect.par (Effect.sync "m04.left" (fun () -> services#billing_refund acc)) (Effect.sync "m04.right" (fun () -> services#audit_log acc)) |> Effect.map (fun (a, b) -> a + b))
  |> Effect.bind (fun acc -> Effect.all [ Effect.pure acc; Effect.sync "m04.all1" (fun () -> services#cache_get acc); Effect.sync "m04.all2" (fun () -> services#cache_set acc) ] |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.all_settled [ Effect.pure acc; Effect.fail (`Cache "m04"); Effect.pure (acc + 1) ] |> Effect.map (List.fold_left (fun n -> function Ok v -> n + v | Error _ -> n) 0))
  |> Effect.bind (fun acc -> Effect.for_each_par_bounded ~max:2 [ acc; acc + 1; acc + 2 ] (fun n -> Effect.sync "m04.each" (fun () -> services#search_query n)) |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.race [ Effect.pure acc; Effect.pure (acc + 1) ])
  |> Effect.bind (fun acc -> Effect.retry Tp_common.schedule (function `External _ -> true | _ -> false) (Effect.pure acc))
  |> Effect.bind (fun acc -> Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.scoped (Effect.acquire_release ~acquire:(Effect.pure acc) ~release:(fun _ -> Effect.sync "m04.release" (fun () -> ())) |> Effect.map (fun v -> v + 1)))
  |> Effect.bind (fun acc -> Supervisor.scoped { run = fun sup -> let open Supervisor.Scope in let* child = start sup (lift (Effect.pure (acc + 4))) in await child })
