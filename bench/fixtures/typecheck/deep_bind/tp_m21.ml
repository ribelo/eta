open Eta

let program services =
  Tp_m20.program services
  |> Effect.bind (fun acc -> Effect.sync "m21.report_build" (fun () -> services#report_build acc))
  |> Effect.bind (fun acc -> if false then Effect.fail (`Validation "m21") else Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.sync "m21.policy_eval" (fun () -> services#policy_eval acc) |> Effect.annotate ~key:"module" ~value:"21" |> Effect.named "m21.named")
  |> Effect.bind (fun acc -> Effect.par (Effect.sync "m21.left" (fun () -> services#tenant_lookup acc)) (Effect.sync "m21.right" (fun () -> services#rate_limit acc)) |> Effect.map (fun (a, b) -> a + b))
  |> Effect.bind (fun acc -> Effect.all [ Effect.pure acc; Effect.sync "m21.all1" (fun () -> services#clock_now acc); Effect.sync "m21.all2" (fun () -> services#user_read acc) ] |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.all_settled [ Effect.pure acc; Effect.fail (`Cache "m21"); Effect.pure (acc + 1) ] |> Effect.map (List.fold_left (fun n -> function Ok v -> n + v | Error _ -> n) 0))
  |> Effect.bind (fun acc -> Effect.for_each_par_bounded ~max:2 [ acc; acc + 1; acc + 2 ] (fun n -> Effect.sync "m21.each" (fun () -> services#user_write n)) |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.race [ Effect.pure acc; Effect.pure (acc + 1) ])
  |> Effect.bind (fun acc -> Effect.retry Tp_common.schedule (function `External _ -> true | _ -> false) (Effect.pure acc))
  |> Effect.bind (fun acc -> Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.scoped (Effect.acquire_release ~acquire:(Effect.pure acc) ~release:(fun _ -> Effect.sync "m21.release" (fun () -> ())) |> Effect.map (fun v -> v + 1)))
  |> Effect.bind (fun acc -> Supervisor.scoped { run = fun sup -> let open Supervisor.Scope in let* child = start sup (lift (Effect.pure (acc + 21))) in await child })
