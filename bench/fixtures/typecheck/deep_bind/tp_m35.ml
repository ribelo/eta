open Eta

let program services =
  Tp_m34.program services
  |> Effect.bind (fun acc -> Effect.sync "m35.search_query" (fun () -> services#search_query acc))
  |> Effect.bind (fun acc -> if false then Effect.fail (`Validation "m35") else Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.sync "m35.notify_send" (fun () -> services#notify_send acc) |> Effect.annotate ~key:"module" ~value:"35" |> Effect.named "m35.named")
  |> Effect.bind (fun acc -> Effect.par (Effect.sync "m35.left" (fun () -> services#feature_flag acc)) (Effect.sync "m35.right" (fun () -> services#config_get acc)) |> Effect.map (fun (a, b) -> a + b))
  |> Effect.bind (fun acc -> Effect.all [ Effect.pure acc; Effect.sync "m35.all1" (fun () -> services#metrics_count acc); Effect.sync "m35.all2" (fun () -> services#auth_check acc) ] |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.all_settled [ Effect.pure acc; Effect.fail (`Cache "m35"); Effect.pure (acc + 1) ] |> Effect.map (List.fold_left (fun n -> function Ok v -> n + v | Error _ -> n) 0))
  |> Effect.bind (fun acc -> Effect.for_each_par_bounded ~max:2 [ acc; acc + 1; acc + 2 ] (fun n -> Effect.sync "m35.each" (fun () -> services#session_get n)) |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.race [ Effect.pure acc; Effect.pure (acc + 1) ])
  |> Effect.bind (fun acc -> Effect.retry Tp_common.schedule (function `External _ -> true | _ -> false) (Effect.pure acc))
  |> Effect.bind (fun acc -> Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.scoped (Effect.acquire_release ~acquire:(Effect.pure acc) ~release:(fun _ -> Effect.sync "m35.release" (fun () -> ())) |> Effect.map (fun v -> v + 1)))
  |> Effect.bind (fun acc -> Supervisor.scoped { run = fun sup -> let open Supervisor.Scope in let* child = start sup (lift (Effect.pure (acc + 35))) in await child })
