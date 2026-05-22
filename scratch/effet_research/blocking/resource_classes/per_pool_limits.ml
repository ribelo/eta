module C = Blocking_research_common
module Pool = Blocking_research_pool

let config ?(max_threads = 4) ?(max_queued = 256) () =
  {
    Pool.max_threads;
    max_queued;
    idle_timeout = 30.0;
    shutdown_timeout = Some 1.0;
    queue_policy = Wait;
  }

let fs_job () =
  C.sleep_blocking 0.020;
  "fs"

let db_job () =
  C.sleep_blocking 0.002;
  "db"

let () =
  C.run_eio @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let pool = Pool.create ~name:"shared_with_class_limits" (config ~max_threads:4 ~max_queued:256 ()) in
  let fs_slots = Eio.Semaphore.make 3 in
  ignore
    (List.init 100 (fun _ ->
         Eio.Fiber.fork_promise ~sw (fun () ->
             Eio.Semaphore.acquire fs_slots;
             Fun.protect
               ~finally:(fun () -> Eio.Semaphore.release fs_slots)
               (fun () -> Pool.submit ~label:"fs.scan" pool (fun () -> fs_job ()) ()))));
  Eio_unix.sleep 0.002;
  let submitted = C.now_ms () in
  let db = Pool.submit ~label:"db.query" pool (fun () -> db_job ()) () in
  let elapsed_ms = C.now_ms () - submitted in
  C.print_summary "per_pool_limits"
    ([
       ("verdict", match db with Ok _ -> "db_completed" | Error e -> Pool.string_of_error e);
       ("db_total_ms", string_of_int elapsed_ms);
     ]
    @ Pool.stats_fields (Pool.stats pool))

