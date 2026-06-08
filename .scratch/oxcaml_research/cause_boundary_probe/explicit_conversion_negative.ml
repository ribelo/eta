(* Candidate D negative: raw same-domain Cause.Die must not cross domains. *)

module Same_domain = struct
  type die = {
    exn : exn;
    backtrace : Printexc.raw_backtrace option;
  }

  type 'err cause =
    | Fail of 'err
    | Die of die
end

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let () =
  let raw = Same_domain.Die { exn = Failure "boom"; backtrace = None } in
  ignore
    (with_scheduler (fun scheduler ->
       Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
         let #(left, right) =
           Parallel.fork_join2 parallel (fun _ -> raw) (fun _ -> raw)
         in
         (left, right))))

