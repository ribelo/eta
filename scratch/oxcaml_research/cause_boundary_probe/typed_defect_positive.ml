(* Candidate C: replace Die at the portable boundary with a typed Effet defect value. *)

open! Portable

type defect : immutable_data =
  | Runtime_defect of {
      kind : string;
      message : string;
      stack : string option;
    }

type ('err : immutable_data) cause : immutable_data =
  | Fail of 'err
  | Die of defect
  | Interrupt
  | Suppressed of {
      primary : 'err cause;
      finalizer : 'err cause;
    }

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let () =
  let cause =
    Die (Runtime_defect { kind = "Failure"; message = "boom"; stack = None })
  in
  let result =
    with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        let #(left, right) =
          Parallel.fork_join2
            parallel
            (fun _ -> cause)
            (fun _ -> Suppressed { primary = cause; finalizer = Interrupt })
        in
        (left, right)))
  in
  match result with
  | Die (Runtime_defect { message = "boom"; _ }),
    Suppressed { primary = Die _; finalizer = Interrupt } -> ()
  | _ -> failwith "typed defect Cause boundary changed shape"

