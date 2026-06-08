open! Portable

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Effet.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ~env:() ()
  in
  ignore
    (with_scheduler (fun scheduler ->
       Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
         Parallel.fork_join2 parallel
           (fun _ -> Effet.Runtime.run rt (Effet.Effect.pure 1))
           (fun _ -> Effet.Runtime.run rt (Effet.Effect.pure 2)))))

