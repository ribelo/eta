open Eta

let program services =
  Tp_m08.program services
  |> Effect.bind (fun acc -> Effect.sync (fun () -> services#cache_set acc))
  |> Effect.bind (fun acc -> if false then Effect.fail (`Validation "m09") else Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.sync (fun () -> services#search_query acc) |> Effect.annotate ~key:"module" ~value:"09" |> Effect.named "m09.named")
  |> Effect.bind (fun acc -> Effect.par (Effect.sync (fun () -> services#notify_send acc)) (Effect.sync (fun () -> services#feature_flag acc)) |> Effect.map (fun (a, b) -> a + b))
  |> Effect.bind (fun acc -> Effect.all [ Effect.pure acc; Effect.sync (fun () -> services#config_get acc); Effect.sync (fun () -> services#metrics_count acc) ] |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.all_settled [ Effect.pure acc; Effect.fail (`Cache "m09"); Effect.pure (acc + 1) ] |> Effect.map (List.fold_left (fun n -> function Ok v -> n + v | Error _ -> n) 0))
  |> Effect.bind (fun acc -> Effect.for_each_par_bounded ~max:2 [ acc; acc + 1; acc + 2 ] (fun n -> Effect.sync (fun () -> services#auth_check n)) |> Effect.map (List.fold_left ( + ) 0))
  |> Effect.bind (fun acc -> Effect.race [ Effect.pure acc; Effect.pure (acc + 1) ])
  |> Effect.bind (fun acc -> Effect.retry (Tp_common.schedule ()) (function `External _ -> true | _ -> false) (Effect.pure acc))
  |> Effect.bind (fun acc -> Effect.pure acc)
  |> Effect.bind (fun acc -> Effect.scoped (Effect.acquire_release ~acquire:(Effect.pure acc) ~release:(fun _ -> Effect.sync (fun () -> ())) |> Effect.map (fun v -> v + 1)))
  |> Effect.bind (fun acc -> Supervisor.scoped { run = fun sup -> let open Supervisor.Scope in let* child = start sup (lift (Effect.pure (acc + 9))) in await child })
