let bad () =
  Eio_main.run @@ fun _env ->
  let queue = Eio.Stream.create 2 in
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () ->
       Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
         let #((), ()) =
           Parallel.fork_join2
             parallel
             (fun _ -> Eio.Stream.add queue 1)
             (fun _ -> Eio.Stream.add queue 2)
         in
         ()))

let () = bad ()
