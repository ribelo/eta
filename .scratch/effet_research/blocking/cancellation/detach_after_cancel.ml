module C = Blocking_research_common
module Pool = Blocking_research_pool

let config ?(max_threads = 1) ?(max_queued = 4) () =
  {
    Pool.max_threads;
    max_queued;
    idle_timeout = 30.0;
    shutdown_timeout = Some 1.0;
    queue_policy = Wait;
  }

let sleep seconds () =
  C.sleep_blocking seconds;
  "done"

let () =
  C.run_eio @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let pool = Pool.create ~name:"detach" (config ~max_threads:1 ()) in
  let before = C.now_us () in
  Pool.submit_detached ~label:"detached.slow" ~sw pool (sleep 0.030) ();
  let returned_us = C.now_us () - before in
  Eio_unix.sleep 0.040;
  C.print_summary "detach_after_cancel"
    ([
       ("verdict", if returned_us < 10_000 then "ok" else "slow_return");
       ("returned_us", string_of_int returned_us);
     ]
    @ Pool.stats_fields (Pool.stats pool))

