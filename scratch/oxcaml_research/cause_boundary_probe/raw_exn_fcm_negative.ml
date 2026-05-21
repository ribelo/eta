(* Candidate A negative: custom exception hidden behind a first-class module.
   If raw exn were accepted as portable, this would be the soundness hazard. *)

module type S = sig
  exception Hidden of string
  val make : string -> exn
end

let pack () =
  (module struct
    exception Hidden of string
    let make msg = Hidden msg
  end : S)

type die : value mod portable = {
  exn : exn;
  backtrace : Printexc.raw_backtrace option;
}

type cause : value mod portable =
  | Die of die

let make_bad () =
  let module M = (val pack ()) in
  Die { exn = M.make "hidden"; backtrace = None }

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let () =
  ignore
    (with_scheduler (fun scheduler ->
       Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
         let #(left, right) =
           Parallel.fork_join2 parallel (fun _ -> make_bad ()) (fun _ -> make_bad ())
         in
         (left, right))))
