open! Portable

let raw = Effet.Cause.die (Failure "boom")

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let () =
  ignore
    (with_scheduler (fun scheduler ->
         Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
           Parallel.fork_join2 parallel (fun _ -> raw) (fun _ -> raw))))
