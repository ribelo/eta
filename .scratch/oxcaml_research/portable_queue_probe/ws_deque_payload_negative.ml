open! Portable

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let () =
  let counter = ref 0 in
  let queue =
    Portable_ws_deque.of_list [ (fun () -> !counter); (fun () -> !counter + 1) ]
  in
  with_scheduler (fun scheduler ->
    Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
      let #(left, right) =
        Parallel.fork_join2
          parallel
          (fun _ -> Portable_ws_deque.steal_opt queue)
          (fun _ -> Portable_ws_deque.steal_opt queue)
      in
      ignore left;
      ignore right))
