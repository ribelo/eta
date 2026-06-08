open! Portable

type delay_batch : immutable_data = { delays_ms : int list }

let dispatch batch =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
          let #(left, right) =
            Parallel.fork_join2 parallel
              (fun _ -> List.nth batch.delays_ms 0)
              (fun _ -> List.nth batch.delays_ms 1)
          in
          left + right))

let () =
  let total = dispatch { delays_ms = [ 120; 140 ] } in
  if total <> 260 then failwith "coordinator delays changed";
  Printf.printf "coordinator_delays_positive total=%d\n%!" total
