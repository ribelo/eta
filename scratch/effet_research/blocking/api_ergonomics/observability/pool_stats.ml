module C = Blocking_research_common
module Pool = Blocking_research_pool

let config =
  {
    Pool.max_threads = 2;
    max_queued = 8;
    idle_timeout = 30.0;
    shutdown_timeout = Some 1.0;
    queue_policy = Reject;
  }

let () =
  C.run_eio @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let pool = Pool.create ~name:"observed" config in
  ignore
    (C.run_many ~sw 6 (fun _ ->
         Pool.submit ~label:"stats.sleep" pool
           (fun () ->
             C.sleep_blocking 0.005;
             1)
           ()));
  C.print_summary "pool_stats"
    (("verdict", "ok") :: Pool.stats_fields (Pool.stats pool))

