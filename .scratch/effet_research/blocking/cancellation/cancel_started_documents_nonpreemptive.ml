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
  let pool = Pool.create ~name:"cancel_started" (config ~max_threads:1 ()) in
  let cancel_ctx = ref None in
  let started = C.now_us () in
  let promise =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Pool.submit ~label:"started.slow" pool (sleep 0.040) ())
  in
  Eio_unix.sleep 0.005;
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  let result = Eio.Promise.await_exn promise in
  let elapsed_us = C.now_us () - started in
  C.print_summary "cancel_started_documents_nonpreemptive"
    ([
       ("verdict", match result with Ok _ -> "started_nonpreemptive_finished" | Error e -> Pool.string_of_error e);
       ("elapsed_us", string_of_int elapsed_us);
     ]
    @ Pool.stats_fields (Pool.stats pool))

