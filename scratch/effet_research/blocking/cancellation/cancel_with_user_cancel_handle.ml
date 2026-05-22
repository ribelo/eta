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
  let pool = Pool.create ~name:"cooperative" (config ~max_threads:1 ()) in
  let cancelled = Atomic.make false in
  let cooperative () =
    let rec loop remaining =
      if Atomic.get cancelled then "cancelled"
      else if remaining = 0 then "finished"
      else (
        Unix.sleepf 0.002;
        loop (remaining - 1))
    in
    loop 50
  in
  let promise =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Pool.submit ~label:"cooperative" pool (fun () -> cooperative ()) ())
  in
  Eio_unix.sleep 0.010;
  Atomic.set cancelled true;
  let result = Eio.Promise.await_exn promise in
  C.print_summary "cancel_with_user_cancel_handle"
    ([
       ("verdict", match result with Ok "cancelled" -> "ok" | Ok other -> other | Error e -> Pool.string_of_error e);
     ]
    @ Pool.stats_fields (Pool.stats pool))

