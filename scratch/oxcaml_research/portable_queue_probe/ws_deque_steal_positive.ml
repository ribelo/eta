open! Portable

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let rec steal_sum q acc =
  match Portable_ws_deque.steal_opt q with
  | None -> acc
  | Some n -> steal_sum q (acc + n)

let () =
  let count = 400 in
  let values = List.init count (fun index -> index + 1) in
  let expected = count * (count + 1) / 2 in
  let queue = Portable_ws_deque.of_list values in
  let result =
    with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        let #(left, right) =
          Parallel.fork_join2
            parallel
            (fun _ -> steal_sum queue 0)
            (fun _ -> steal_sum queue 0)
        in
        left + right))
  in
  if result <> expected
  then failwith "Portable_ws_deque stealers did not consume each item exactly once"

