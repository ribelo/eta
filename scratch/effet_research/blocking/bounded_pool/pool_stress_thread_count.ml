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
  let pool =
    Pool.create ~name:"stress_threads" (config ~max_threads:4 ~max_queued:64 ~queue_policy:Pool.Wait ())
  in
  let before_threads = C.thread_count () |> Option.value ~default:(-1) in
  let result, heartbeat, elapsed_us =
    C.with_heartbeat (fun () ->
        ignore
          (C.run_many ~sw 100 (fun _ ->
               Pool.submit ~label:"stress.sleep" pool (sleep_job 0.005) ())))
  in
  let after_threads = C.thread_count () |> Option.value ~default:(-1) in
  let stats = Pool.stats pool in
  C.print_summary "pool_stress_thread_count"
    ([
       ("verdict", match result with Ok () -> "ok" | Error (exn, _) -> Printexc.to_string exn);
       ("threads_before", string_of_int before_threads);
       ("threads_after", string_of_int after_threads);
       ("elapsed_us", string_of_int elapsed_us);
     ]
    @ C.latency_fields "heartbeat" heartbeat
    @ Pool.stats_fields stats)

