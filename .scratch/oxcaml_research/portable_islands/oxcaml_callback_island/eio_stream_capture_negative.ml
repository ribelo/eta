open! Portable

module Island = struct
  let map_pair (f @ portable) left right =
    let scheduler = Parallel_scheduler.create ~max_domains:2 () in
    Fun.protect
      ~finally:(fun () -> Parallel_scheduler.stop scheduler)
      (fun () ->
        Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
            let #(left, right) =
              Parallel.fork_join2 parallel (fun _ -> f left) (fun _ -> f right)
            in
            (left, right)))
end

let () =
  Eio_main.run @@ fun _env ->
  let stream = Eio.Stream.create 8 in
  ignore
    (Island.map_pair
       (fun n ->
         Eio.Stream.add stream n;
         n)
       1 2)
