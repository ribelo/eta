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
  let pool = Pool.create ~name:"raise_after_cancel" config in
  let cancel_ctx = ref None in
  let promise =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Pool.submit ~label:"raises.after.cancel" pool
          (fun () ->
            Unix.sleepf 0.020;
            raise (Failure "late failure"))
          ())
  in
  Eio_unix.sleep 0.005;
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  let result = Eio.Promise.await_exn promise in
  C.print_summary "blocking_raises_after_cancel"
    [ ("verdict", match result with Error (Pool.Worker_raised _) -> "worker_exception_observed" | Error e -> Pool.string_of_error e | Ok _ -> "unexpected_ok") ]

