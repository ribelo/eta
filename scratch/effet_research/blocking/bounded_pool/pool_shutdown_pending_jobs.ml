module C = Blocking_research_common
module Pool = Blocking_research_pool

let config ?(max_threads = 2) ?(max_queued = 4) ?(queue_policy = Pool.Wait) () =
  {
    Pool.max_threads;
    max_queued;
    idle_timeout = 30.0;
    shutdown_timeout = Some 1.0;
    queue_policy;
  }

let sleep_job seconds () =
  C.sleep_blocking seconds;
  "done"

let print_stats probe pool extra =
  C.print_summary probe (extra @ Pool.stats_fields (Pool.stats pool))

let () =
  C.run_eio @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let pool = Pool.create ~name:"shutdown_pending" (config ~max_threads:1 ~max_queued:2 ()) in
  let first =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Pool.submit ~label:"pending.first" pool (sleep_job 0.030) ())
  in
  let second =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Pool.submit ~label:"pending.second" pool (sleep_job 0.001) ())
  in
  Eio_unix.sleep 0.002;
  Pool.shutdown pool;
  let after_shutdown = Pool.submit ~label:"after.shutdown" pool (sleep_job 0.001) () in
  ignore (Eio.Promise.await_exn first);
  ignore (Eio.Promise.await_exn second);
  print_stats "pool_shutdown_pending_jobs" pool
    [
      ("verdict", match after_shutdown with Error Pool.Pool_shutting_down -> "ok" | Error e -> Pool.string_of_error e | Ok _ -> "unexpected_ok");
    ]

