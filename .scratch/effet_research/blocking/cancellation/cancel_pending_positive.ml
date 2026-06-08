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
  let pool = Pool.create ~name:"cancel_pending" (config ~max_threads:1 ~max_queued:4 ()) in
  let first =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Pool.submit ~label:"started" pool (sleep 0.040) ())
  in
  Eio_unix.sleep 0.002;
  let cancel_ctx = ref None in
  let second =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Pool.submit ~label:"pending" pool (sleep 0.001) ())
  in
  Eio_unix.sleep 0.002;
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  let pending = Eio.Promise.await_exn second in
  ignore (Eio.Promise.await_exn first);
  C.print_summary "cancel_pending_positive"
    ([
       ("verdict", match pending with Error Pool.Cancelled_before_start -> "ok" | Error e -> Pool.string_of_error e | Ok _ -> "unexpected_ok");
     ]
    @ Pool.stats_fields (Pool.stats pool))

