open! Portable

type counter : value mod portable contended = { value : int Atomic.t }

module Island = struct
  let with_scheduler f =
    let scheduler = Parallel_scheduler.create ~max_domains:2 () in
    Fun.protect
      ~finally:(fun () -> Parallel_scheduler.stop scheduler)
      (fun () -> f scheduler)

  let map_pair (f @ portable) left right =
    with_scheduler (fun scheduler ->
        Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
            let #(left, right) =
              Parallel.fork_join2 parallel (fun _ -> f left) (fun _ -> f right)
            in
            (left, right)))
end

let (bump @ portable) counter =
  Atomic.update counter.value ~pure_f:(fun n -> n + 1);
  Atomic.get counter.value

let () =
  let counter = { value = Atomic.make 0 } in
  let _left, _right = Island.map_pair bump counter counter in
  let final = Atomic.get counter.value in
  if final <> 2 then failwith "portable atomic capture did not update twice";
  Printf.printf "island atomic_capture=true final=%d\n%!" final
