module C = Blocking_research_common
module Pool = Blocking_research_pool

let iterations = 4_000_000
let items = List.init 16 (fun i -> i + 1)

let cpu_work n =
  let rec loop i acc =
    if i = 0 then acc
    else loop (i - 1) (((acc lxor (i * 33)) + n) land 0x3fffffff)
  in
  loop iterations n

let (cpu_work_portable @ portable) n =
  let rec loop i acc =
    if i = 0 then acc
    else loop (i - 1) (((acc lxor (i * 33)) + n) land 0x3fffffff)
  in
  loop iterations n

let config =
  {
    Pool.max_threads = 4;
    max_queued = 32;
    idle_timeout = 30.0;
    shutdown_timeout = Some 1.0;
    queue_policy = Wait;
  }

let () =
  C.run_eio @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let pool = Pool.create ~name:"cpu_blocking" config in
  let io_wait_ms = ref (-1) in
  let io_probe = ref "not_run" in
  let result, heartbeat, elapsed_us =
    C.with_heartbeat (fun () ->
        let cpu_jobs =
          List.init (List.length items) (fun i ->
              Eio.Fiber.fork_promise ~sw (fun () ->
                  Pool.submit ~label:"cpu.bad" pool cpu_work (List.nth items i)))
        in
        Eio_unix.sleep 0.001;
        let io_submitted = C.now_ms () in
        let io_result =
          Pool.submit ~label:"io.behind.cpu" pool
            (fun () ->
              C.sleep_blocking 0.001;
              "io")
            ()
        in
        io_wait_ms := C.now_ms () - io_submitted;
        io_probe :=
          (match io_result with Ok _ -> "ok" | Error e -> Pool.string_of_error e);
        ignore (List.map Eio.Promise.await_exn cpu_jobs))
  in
  C.print_summary "cpu_blocking_pool"
    ([
       ("items", string_of_int (List.length items));
       ("verdict", match result with Ok () -> "ok" | Error (exn, _) -> Printexc.to_string exn);
       ("io_probe", !io_probe);
       ("io_wait_ms", string_of_int !io_wait_ms);
       ("elapsed_us", string_of_int elapsed_us);
     ]
    @ C.latency_fields "heartbeat" heartbeat
    @ Pool.stats_fields (Pool.stats pool))
