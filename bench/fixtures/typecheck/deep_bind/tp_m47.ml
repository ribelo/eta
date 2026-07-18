open Eta

let program services =
  Tp_m46.program services
  |> Effect.bind (fun acc -> Effect.sync (fun () -> services#policy_eval acc))
  |> Effect.bind (fun acc -> if false then Effect.fail (`Validation "m47") else Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.sync (fun () -> services#tenant_lookup acc) |> Effect.annotate ~key:"module" ~value:"47" |> Effect.named "m47.named")
  |> Effect.bind (fun acc -> Effect.par (Effect.sync (fun () -> services#rate_limit acc)) (Effect.sync (fun () -> services#clock_now acc)) |> Effect.map (fun (a, b) -> a + b))
  |> Effect.bind (fun acc -> Effect.all [ Effect.pure acc; Effect.sync (fun () -> services#user_read acc); Effect.sync (fun () -> services#user_write acc) ] |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.all_settled [ Effect.pure acc; Effect.fail (`Cache "m47"); Effect.pure (acc + 1) ] |> Effect.map (List.fold_left (fun n -> function Ok v -> n + v | Error _ -> n) 0))
  |> Effect.bind (fun acc -> Effect.map_par ~max_concurrent:2 (fun n -> Effect.sync (fun () -> services#order_read n)) [ acc; acc + 1; acc + 2 ] |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.race [ Effect.pure acc; Effect.pure (acc + 1) ])
  |> Effect.bind (fun acc -> Effect.retry ~schedule:(Tp_common.schedule ()) ~while_:(function `External _ -> true | _ -> false) (Effect.pure acc))
  |> Effect.bind (fun acc -> Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.scoped (Effect.acquire_release ~acquire:(Effect.pure acc) ~release:(fun _ -> Effect.sync (fun () -> ())) |> Effect.map (fun v -> v + 1)))
  |> Effect.bind (fun acc -> Supervisor.scoped { run = fun sup -> let open Supervisor.Scope in let* child = start sup (lift (Effect.pure (acc + 47))) in await child })
