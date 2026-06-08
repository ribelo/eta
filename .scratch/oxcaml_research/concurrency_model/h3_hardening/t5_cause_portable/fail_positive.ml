open! Portable

type typed_error : immutable_data = Worker_failed of string

let cause : typed_error Effet.Cause.Portable.t =
  Effet.Cause.Portable.Fail (Worker_failed "typed")

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
  | Effet.Cause.Portable.Fail (Worker_failed "typed") ->
      Printf.printf "fail_positive immutable_typed_payload=true\n%!"
  | _ -> failwith "Fail changed shape"

