open Eta

let program services =
  Tp_m12.program services
  |> Effect.bind (fun acc -> Effect.sync "m13.config_get" (fun () -> services#config_get acc))
  |> Effect.bind (fun acc -> if false then Effect.fail (`Validation "m13") else Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.sync "m13.metrics_count" (fun () -> services#metrics_count acc) |> Effect.annotate ~key:"module" ~value:"13" |> Effect.named "m13.named")
  |> Effect.bind (fun acc -> Effect.par (Effect.sync "m13.left" (fun () -> services#auth_check acc)) (Effect.sync "m13.right" (fun () -> services#session_get acc)) |> Effect.map (fun (a, b) -> a + b))
  |> Effect.bind (fun acc -> Effect.all [ Effect.pure acc; Effect.sync "m13.all1" (fun () -> services#inventory_get acc); Effect.sync "m13.all2" (fun () -> services#shipment_quote acc) ] |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.all_settled [ Effect.pure acc; Effect.fail (`Cache "m13"); Effect.pure (acc + 1) ] |> Effect.map (List.fold_left (fun n -> function Ok v -> n + v | Error _ -> n) 0))
  |> Effect.bind (fun acc -> Effect.for_each_par_bounded ~max:2 [ acc; acc + 1; acc + 2 ] (fun n -> Effect.sync "m13.each" (fun () -> services#email_send n)) |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.race [ Effect.pure acc; Effect.pure (acc + 1) ])
  |> Effect.bind (fun acc -> Effect.retry Tp_common.schedule (function `External _ -> true | _ -> false) (Effect.pure acc))
  |> Effect.bind (fun acc -> Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.scoped (Effect.acquire_release ~acquire:(Effect.pure acc) ~release:(fun _ -> Effect.sync "m13.release" (fun () -> ())) |> Effect.map (fun v -> v + 1)))
  |> Effect.bind (fun acc -> Supervisor.scoped { run = fun sup -> let open Supervisor.Scope in let* child = start sup (lift (Effect.pure (acc + 13))) in await child })
