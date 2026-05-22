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
  let fs_pool = Pool.create ~name:"fs" (config ~max_threads:4 ~max_queued:256 ()) in
  let db_pool = Pool.create ~name:"db" (config ~max_threads:2 ~max_queued:32 ()) in
  ignore
    (List.init 100 (fun _ ->
         Eio.Fiber.fork_promise ~sw (fun () ->
             Pool.submit ~label:"fs.scan" fs_pool (fun () -> fs_job ()) ())));
  Eio_unix.sleep 0.002;
  let submitted = C.now_ms () in
  let db = Pool.submit ~label:"db.query" db_pool (fun () -> db_job ()) () in
  let elapsed_ms = C.now_ms () - submitted in
  C.print_summary "db_fs_separate_pools"
    ([
       ("verdict", match db with Ok _ -> "db_completed" | Error e -> Pool.string_of_error e);
       ("db_total_ms", string_of_int elapsed_ms);
     ]
    @ Pool.stats_fields (Pool.stats db_pool))

