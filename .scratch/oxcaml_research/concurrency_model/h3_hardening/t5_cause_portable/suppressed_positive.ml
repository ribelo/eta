open! Portable

type typed_error : immutable_data = Primary | Finalizer

let cause : typed_error Effet.Cause.Portable.t =
  Effet.Cause.Portable.Suppressed
    {
      primary = Effet.Cause.Portable.Fail Primary;
      finalizer = Effet.Cause.Portable.Fail Finalizer;
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
  | Effet.Cause.Portable.Suppressed
      {
        primary = Effet.Cause.Portable.Fail Primary;
        finalizer = Effet.Cause.Portable.Fail Finalizer;
      } ->
      Printf.printf "suppressed_positive primary_and_finalizer=true\n%!"
  | _ -> failwith "Suppressed changed shape"

