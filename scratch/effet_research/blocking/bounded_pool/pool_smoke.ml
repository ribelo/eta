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
  let pool = Pool.create ~name:"smoke" (config ()) in
  let result = Pool.submit ~label:"smoke.job" pool (fun n -> n + 1) 41 in
  print_stats "pool_smoke" pool
    [
      ( "verdict",
        match result with Ok 42 -> "ok" | Ok _ -> "wrong_value" | Error e -> Pool.string_of_error e );
    ]

