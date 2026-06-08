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
    Pool.create ~name:"wait" (config ~max_threads:1 ~max_queued:1 ~queue_policy:Pool.Wait ())
  in
  let started = C.now_us () in
  let results =
    C.run_many ~sw 3 (fun _ ->
        Pool.submit ~label:"wait.sleep" pool (sleep_job 0.020) ())
  in
  let elapsed_us = C.now_us () - started in
  let ok_count =
    List.fold_left
      (fun acc -> function Ok _ -> acc + 1 | Error _ -> acc)
      0 results
  in
  print_stats "pool_backpressure_wait" pool
    [
      ("verdict", if ok_count = 3 then "ok" else "failed");
      ("ok_count", string_of_int ok_count);
      ("elapsed_us", string_of_int elapsed_us);
    ]

