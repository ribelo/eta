(* Candidate D: keep raw Cause.Die same-domain only and require explicit conversion
   before crossing a domain boundary. *)

open! Portable

module Same_domain = struct
  type die = {
    exn : exn;
    backtrace : Printexc.raw_backtrace option;
    span_name : string option;
    annotations : (string * string) list;
  }

  type 'err cause =
    | Fail of 'err
    | Die of die
    | Interrupt
    | Concurrent of 'err cause list
end

module Portable_cause = struct
  type diagnostic : value mod portable = {
    kind : string;
    message : string;
    stack : string option;
    span_name : string option;
    annotations : (string * string) list;
  }

  type ('err : value mod portable) t : value mod portable =
    | Fail of 'err
    | Die of diagnostic
    | Interrupt
    | Concurrent of 'err t list

  let rec of_same_domain :
      type (err : value mod portable). (err -> err) -> err Same_domain.cause -> err t =
   fun map_err -> function
    | Same_domain.Fail err -> Fail (map_err err)
    | Same_domain.Die die ->
        Die {
          kind = Printexc.to_string die.exn;
          message = Printexc.to_string die.exn;
          stack = Option.map Printexc.raw_backtrace_to_string die.backtrace;
          span_name = die.span_name;
          annotations = die.annotations;
        }
    | Same_domain.Interrupt -> Interrupt
    | Same_domain.Concurrent causes ->
        Concurrent (List.map (of_same_domain map_err) causes)
end

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let () =
  let result =
    with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        let make_portable () =
          let raw =
            Same_domain.Concurrent [
              Same_domain.Die {
                exn = Failure "boom";
                backtrace = None;
                span_name = Some "worker";
                annotations = [ "phase", "boundary" ];
              };
              Same_domain.Interrupt;
            ]
          in
          Portable_cause.of_same_domain (fun err -> err) raw
        in
        let #(left, right) =
          Parallel.fork_join2 parallel (fun _ -> make_portable ()) (fun _ -> make_portable ())
        in
        (left, right)))
  in
  match result with
  | Portable_cause.Concurrent [ Portable_cause.Die { span_name = Some "worker"; _ }; Interrupt ],
    Portable_cause.Concurrent _ -> ()
  | _ -> failwith "explicit Cause.Portable conversion changed shape"
