open! Portable

type typed_error : immutable_data = Left | Right

let cause : typed_error Effet.Cause.Portable.t =
  Effet.Cause.Portable.Concurrent
    [ Effet.Cause.Portable.Fail Left; Effet.Cause.Portable.Fail Right ]

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
  | Effet.Cause.Portable.Concurrent
      [ Effet.Cause.Portable.Fail Left; Effet.Cause.Portable.Fail Right ] ->
      Printf.printf "concurrent_positive sibling_count=2\n%!"
  | _ -> failwith "Concurrent changed shape"

