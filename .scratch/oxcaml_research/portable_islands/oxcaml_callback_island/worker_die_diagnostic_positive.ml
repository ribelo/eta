open! Portable

type worker_die : immutable_data = {
  kind : string;
  message : string;
}

module Island = struct
  let with_scheduler f =
    let scheduler = Parallel_scheduler.create ~max_domains:2 () in
    Fun.protect
      ~finally:(fun () -> Parallel_scheduler.stop scheduler)
      (fun () -> f scheduler)

  let map_pair_or_die (f @ portable) left right =
    try
      Ok
        (with_scheduler (fun scheduler ->
             Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
                 let #(left, right) =
                   Parallel.fork_join2 parallel
                     (fun _ -> f left)
                     (fun _ -> f right)
                 in
                 (left, right))))
    with exn ->
      Error
        {
          kind = Printexc.exn_slot_name exn;
          message = Printexc.to_string exn;
        }
end

let () =
  match
    Island.map_pair_or_die
      (fun n ->
        match n with
        | 0 -> failwith "zero"
        | _ -> n)
      1 0
  with
  | Ok _ -> failwith "worker die was not materialized"
  | Error die ->
      if die.message = "" then failwith "empty worker die diagnostic";
      Printf.printf "island worker_die_diagnostic=true kind=%s\n%!" die.kind
