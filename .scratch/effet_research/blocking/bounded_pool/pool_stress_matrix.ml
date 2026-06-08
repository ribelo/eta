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

let run_b1 ~sw count delay =
  C.with_heartbeat (fun () ->
      ignore
        (C.run_many ~sw count (fun _ ->
             Eio_unix.run_in_systhread ~label:"b1.sleep" (fun () ->
                 C.sleep_blocking delay))))

let run_b2 ~sw count delay =
  let pool =
    Pool.create ~name:"b2_matrix" (config ~max_threads:4 ~max_queued:64 ~queue_policy:Pool.Wait ())
  in
  let result =
    C.with_heartbeat (fun () ->
        ignore
          (C.run_many ~sw count (fun _ ->
               Pool.submit ~label:"b2.sleep" pool (sleep_job delay) ())))
  in
  (pool, result)

let () =
  C.run_eio @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let count = 100 in
  let b1_result, b1_hb, b1_elapsed = run_b1 ~sw count 0.003 in
  C.print_summary "pool_stress_matrix"
    ([
       ("mode", "B1_run_in_systhread");
       ("jobs", string_of_int count);
       ("verdict", match b1_result with Ok () -> "ok" | Error (exn, _) -> Printexc.to_string exn);
       ("elapsed_us", string_of_int b1_elapsed);
       ("threads_after", string_of_int (C.thread_count () |> Option.value ~default:(-1)));
     ]
    @ C.latency_fields "heartbeat" b1_hb);
  let pool, (b2_result, b2_hb, b2_elapsed) = run_b2 ~sw count 0.003 in
  C.print_summary "pool_stress_matrix"
    ([
       ("mode", "B2_bounded_pool");
       ("jobs", string_of_int count);
       ("verdict", match b2_result with Ok () -> "ok" | Error (exn, _) -> Printexc.to_string exn);
       ("elapsed_us", string_of_int b2_elapsed);
       ("threads_after", string_of_int (C.thread_count () |> Option.value ~default:(-1)));
     ]
    @ C.latency_fields "heartbeat" b2_hb
    @ Pool.stats_fields (Pool.stats pool))

