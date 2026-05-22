open Eta

let program services =
  Tp_m24.program services
  |> Effect.bind (fun acc -> Effect.sync "m25.clock_now" (fun () -> services#clock_now acc))
  |> Effect.bind (fun acc -> if false then Effect.fail (`Validation "m25") else Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.sync "m25.user_read" (fun () -> services#user_read acc) |> Effect.annotate ~key:"module" ~value:"25" |> Effect.named "m25.named")
  |> Effect.bind (fun acc -> Effect.par (Effect.sync "m25.left" (fun () -> services#user_write acc)) (Effect.sync "m25.right" (fun () -> services#order_read acc)) |> Effect.map (fun (a, b) -> a + b))
  |> Effect.bind (fun acc -> Effect.all [ Effect.pure acc; Effect.sync "m25.all1" (fun () -> services#order_write acc); Effect.sync "m25.all2" (fun () -> services#billing_charge acc) ] |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.all_settled [ Effect.pure acc; Effect.fail (`Cache "m25"); Effect.pure (acc + 1) ] |> Effect.map (List.fold_left (fun n -> function Ok v -> n + v | Error _ -> n) 0))
  |> Effect.bind (fun acc -> Effect.for_each_par_bounded ~max:2 [ acc; acc + 1; acc + 2 ] (fun n -> Effect.sync "m25.each" (fun () -> services#billing_refund n)) |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.race [ Effect.pure acc; Effect.pure (acc + 1) ])
  |> Effect.bind (fun acc -> Effect.retry Tp_common.schedule (function `External _ -> true | _ -> false) (Effect.pure acc))
  |> Effect.bind (fun acc -> Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.scoped (Effect.acquire_release ~acquire:(Effect.pure acc) ~release:(fun _ -> Effect.sync "m25.release" (fun () -> ())) |> Effect.map (fun v -> v + 1)))
  |> Effect.bind (fun acc -> Supervisor.scoped { run = fun sup -> let open Supervisor.Scope in let* child = start sup (lift (Effect.pure (acc + 25))) in await child })
