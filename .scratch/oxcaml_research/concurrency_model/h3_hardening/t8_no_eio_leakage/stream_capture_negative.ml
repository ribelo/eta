open! Portable

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let () =
  Eio_main.run @@ fun _env ->
  let stream = Eio.Stream.create 2 in
  ignore
    (with_scheduler (fun scheduler ->
       Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
         Parallel.fork_join2 parallel
           (fun _ -> Eio.Stream.add stream 1)
           (fun _ -> Eio.Stream.add stream 2))))

