open Eta

let program services =
  Tp_m21.program services
  |> Effect.bind (fun acc -> Effect.sync "m22.policy_eval" (fun () -> services#policy_eval acc))
  |> Effect.bind (fun acc -> if false then Effect.fail (`Validation "m22") else Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.sync "m22.tenant_lookup" (fun () -> services#tenant_lookup acc) |> Effect.annotate ~key:"module" ~value:"22" |> Effect.named "m22.named")
  |> Effect.bind (fun acc -> Effect.par (Effect.sync "m22.left" (fun () -> services#rate_limit acc)) (Effect.sync "m22.right" (fun () -> services#clock_now acc)) |> Effect.map (fun (a, b) -> a + b))
  |> Effect.bind (fun acc -> Effect.all [ Effect.pure acc; Effect.sync "m22.all1" (fun () -> services#user_read acc); Effect.sync "m22.all2" (fun () -> services#user_write acc) ] |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.all_settled [ Effect.pure acc; Effect.fail (`Cache "m22"); Effect.pure (acc + 1) ] |> Effect.map (List.fold_left (fun n -> function Ok v -> n + v | Error _ -> n) 0))
  |> Effect.bind (fun acc -> Effect.for_each_par_bounded ~max:2 [ acc; acc + 1; acc + 2 ] (fun n -> Effect.sync "m22.each" (fun () -> services#order_read n)) |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.race [ Effect.pure acc; Effect.pure (acc + 1) ])
  |> Effect.bind (fun acc -> Effect.retry Tp_common.schedule (function `External _ -> true | _ -> false) (Effect.pure acc))
  |> Effect.bind (fun acc -> Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.scoped (Effect.acquire_release ~acquire:(Effect.pure acc) ~release:(fun _ -> Effect.sync "m22.release" (fun () -> ())) |> Effect.map (fun v -> v + 1)))
  |> Effect.bind (fun acc -> Supervisor.scoped { run = fun sup -> let open Supervisor.Scope in let* child = start sup (lift (Effect.pure (acc + 22))) in await child })
