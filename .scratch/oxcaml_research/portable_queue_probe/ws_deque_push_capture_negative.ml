open! Portable

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let () =
  let queue = Portable_ws_deque.create () in
  with_scheduler (fun scheduler ->
    Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
      let #((), ()) =
        Parallel.fork_join2
          parallel
          (fun _ -> Portable_ws_deque.push queue 1)
          (fun _ -> ignore (Portable_ws_deque.steal_opt queue))
      in
      ()))

