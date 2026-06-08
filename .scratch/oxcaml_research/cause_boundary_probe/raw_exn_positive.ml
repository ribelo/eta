(* Candidate A: keep raw exn + raw_backtrace in a portable Cause boundary.
   Expected result: compile failure documents why this is rejected. *)

type die : value mod portable = {
  exn : exn;
  backtrace : Printexc.raw_backtrace option;
  span_name : string option;
  annotations : (string * string) list;
}

type cause : value mod portable =
  | Die of die
  | Interrupt

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let make_sample () =
  Die {
    exn = Failure "boom";
    backtrace = None;
    span_name = Some "worker";
    annotations = [ "k", "v" ];
  }

let () =
  let result =
    with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        let #(left, right) =
          Parallel.fork_join2 parallel (fun _ -> make_sample ()) (fun _ -> Interrupt)
        in
        (left, right)))
  in
  match result with
  | Die { span_name = Some "worker"; _ }, Interrupt -> ()
  | _ -> failwith "raw exn Cause boundary changed shape"
