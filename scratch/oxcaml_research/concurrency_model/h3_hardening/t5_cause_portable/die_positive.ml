open! Portable

let cause : string Effet.Cause.Portable.t =
  Effet.Cause.Portable.Die
    {
      kind = "Failure";
      message = "Failure(\"boom\")";
      backtrace = Some "worker-backtrace";
      span_name = Some "worker";
      annotations = [ ("task", "die") ];
    }

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let () =
  let left, _right =
    with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        let #(left, right) =
          Parallel.fork_join2 parallel (fun _ -> cause) (fun _ -> cause)
        in
        (left, right)))
  in
  match left with
  | Effet.Cause.Portable.Die { message = "Failure(\"boom\")"; span_name = Some "worker"; _ } ->
      Printf.printf "die_positive materialized=true\n%!"
  | _ -> failwith "Die changed shape"

