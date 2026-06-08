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
    Pool.create ~name:"reject" (config ~max_threads:1 ~max_queued:1 ~queue_policy:Pool.Reject ())
  in
  let results =
    C.run_many ~sw 6 (fun _ ->
        Pool.submit ~label:"reject.sleep" pool (sleep_job 0.030) ())
  in
  let rejected =
    List.fold_left
      (fun acc -> function Error Pool.Pool_full -> acc + 1 | _ -> acc)
      0 results
  in
  print_stats "pool_backpressure_reject" pool
    [
      ("verdict", if rejected > 0 then "ok" else "no_reject");
      ("rejected_observed", string_of_int rejected);
    ]

