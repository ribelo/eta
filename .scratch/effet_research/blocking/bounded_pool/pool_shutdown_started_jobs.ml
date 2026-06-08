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
  let pool = Pool.create ~name:"shutdown_started" (config ~max_threads:1 ~max_queued:4 ()) in
  let promise =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Pool.submit ~label:"started.slow" pool (sleep_job 0.030) ())
  in
  Eio_unix.sleep 0.005;
  Pool.shutdown pool;
  let result = Eio.Promise.await_exn promise in
  print_stats "pool_shutdown_started_jobs" pool
    [
      ("verdict", match result with Ok _ -> "started_finished" | Error e -> Pool.string_of_error e);
    ]

