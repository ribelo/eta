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

let (never_returns @ portable) n =
  let rec loop x = loop (x + 1) in
  loop n

let _compiled_but_not_run = never_returns
