(* Candidate B: materialize exn/backtrace to portable strings at the domain boundary. *)

open! Portable

type die_kind =
  | K_failure
  | K_invalid_argument
  | Other of string

type diagnostic : value mod portable = {
  kind : die_kind;
  message : string;
  stack : string option;
  span_name : string option;
  annotations : (string * string) list;
}

type ('err : value mod portable) cause : value mod portable =
  | Fail of 'err
  | Die of diagnostic
  | Interrupt
  | Concurrent of 'err cause list

let classify exn =
  match exn with
  | Failure message -> (K_failure, message)
  | Invalid_argument message -> (K_invalid_argument, message)
  | exn -> (Other (Printexc.to_string exn), Printexc.to_string exn)

let of_exn ?bt ?span_name ?(annotations = []) exn =
  let kind, message = classify exn in
  let stack = Option.map Printexc.raw_backtrace_to_string bt in
  Die { kind; message; stack; span_name; annotations }

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let () =
  let result =
    with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        let #(left, right) =
          Parallel.fork_join2
            parallel
            (fun _ -> of_exn ~span_name:"worker" (Failure "boom"))
            (fun _ ->
              Concurrent [ of_exn ~span_name:"worker" (Failure "boom"); Interrupt ])
        in
        (left, right)))
  in
  match result with
  | Die { kind = K_failure; message = "boom"; stack = None; span_name = Some "worker"; _ },
    Concurrent [ Die _; Interrupt ] -> ()
  | _ -> failwith "materialized Cause boundary changed shape"
