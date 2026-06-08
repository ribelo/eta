let bad () =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () ->
       let counter = ref 0 in
       Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
         let #((), ()) =
           Parallel.fork_join2
             parallel
             (fun _ -> incr counter)
             (fun _ -> incr counter)
         in
         ()))

let () = bad ()
