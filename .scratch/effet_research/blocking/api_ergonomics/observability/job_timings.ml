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
  let pool = Pool.create ~name:"timings" config in
  ignore
    (C.run_many ~sw 4 (fun i ->
         Pool.submit ~label:("timed." ^ string_of_int i) pool
           (fun n ->
             C.sleep_blocking (0.002 *. float_of_int (n + 1));
             n)
           i));
  let timings = Pool.timings pool in
  let total_run_ms = List.fold_left (fun acc t -> acc + t.Pool.run_ms) 0 timings in
  C.print_summary "job_timings"
    [
      ("verdict", if List.length timings = 4 && total_run_ms > 0 then "ok" else "bad_timings");
      ("timing_count", string_of_int (List.length timings));
      ("total_run_ms", string_of_int total_run_ms);
    ]

