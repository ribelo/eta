open! Portable

let (jitter @ portable) base =
  let factor = 1.0 +. Random.float 1.0 in
  int_of_float (float_of_int base *. factor)

let () =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
          let #(a, b) =
            Parallel.fork_join2 parallel
              (fun _ -> jitter 100)
              (fun _ -> jitter 100)
          in
          ignore (a, b)))
