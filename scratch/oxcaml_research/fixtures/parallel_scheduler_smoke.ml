let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let smoke () =
  let result =
    with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        let #(left, right) =
          Parallel.fork_join2 parallel (fun _ -> 21) (fun _ -> 21)
        in
        left + right))
  in
  if result <> 42 then failwith "parallel scheduler returned wrong result"

let () = smoke ()
