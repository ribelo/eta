module C = Blocking_research_common
module Pool = Blocking_research_pool
open Effet

let config =
  {
    Pool.max_threads = 1;
    max_queued = 8;
    idle_timeout = 30.0;
    shutdown_timeout = Some 1.0;
    queue_policy = Wait;
  }

let run_pool_as_effect pool label f x =
  Effect.thunk label (fun () ->
      match Pool.submit ~label pool f x with
      | Ok value -> value
      | Error (Pool.Worker_raised (exn, bt)) -> Printexc.raise_with_backtrace exn bt
      | Error e -> failwith (Pool.string_of_error e))

let () =
  C.run_eio @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let pool = Pool.create ~name:"raise_after_detach" config in
  Pool.submit_detached ~label:"detached.raises" ~sw pool
    (fun () ->
      Unix.sleepf 0.010;
      raise (Failure "detached failure"))
    ();
  Eio_unix.sleep 0.030;
  C.print_summary "blocking_raises_after_detach"
    (("verdict", "detached_exception_dropped_in_probe_logged_by_stats")
     :: Pool.stats_fields (Pool.stats pool))

