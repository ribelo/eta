open! Portable

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let cause =
  Effet.Cause.concurrent
    [
      Effet.Cause.fail "typed";
      Effet.Cause.die_with_diagnostics ~span_name:"worker"
        ~annotations:[ ("branch", "left") ] (Failure "boom");
    ]

let portable = Effet.Cause.to_portable (fun err -> err) cause

let () =
  let result =
    with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        let #(left, right) =
          Parallel.fork_join2 parallel (fun _ -> portable) (fun _ -> portable)
        in
        (left, right)))
  in
  match result with
  | ( Effet.Cause.Portable.Concurrent
        [
          Effet.Cause.Portable.Fail "typed";
          Effet.Cause.Portable.Die
            {
              message = "Failure(\"boom\")";
              span_name = Some "worker";
              annotations = [ ("branch", "left") ];
              _;
            };
        ],
      Effet.Cause.Portable.Concurrent _ ) ->
      ()
  | _ -> failwith "portable cause changed shape"
