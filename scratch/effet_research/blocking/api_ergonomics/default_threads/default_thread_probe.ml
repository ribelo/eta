module C = Blocking_research_common

type candidate = { label : string; max_threads : int }

type workload = {
  label : string;
  jobs : int;
  run : int -> unit;
}

type sample = {
  threads : int;
  rss_kb : int;
}

let cpu_count () = max 1 (Domain.recommended_domain_count ())

let candidates () =
  let cpu = cpu_count () in
  [
    { label = "num_cpu_div_2"; max_threads = max 1 (cpu / 2) };
    { label = "num_cpu"; max_threads = cpu };
    { label = "num_cpu_x2"; max_threads = cpu * 2 };
    { label = "fixed_32"; max_threads = 32 };
    { label = "fixed_128"; max_threads = 128 };
    { label = "fixed_512"; max_threads = 512 };
  ]

let cpu_for_ms ms =
  let deadline = C.now_us () + (ms * 1000) in
  let acc = ref 0x12345 in
  while C.now_us () < deadline do
    for i = 1 to 1000 do
      acc := ((!acc lxor (i * 1103515245)) + 12345) land 0x3fffffff
    done
  done;
  ignore !acc

let syscall_heavy i =
  let path =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "effet-default-thread-probe-%d.tmp" i)
  in
  let oc = open_out_bin path in
  output_string oc "effet";
  close_out oc;
  ignore (Unix.stat path);
  let ic = open_in_bin path in
  really_input_string ic 5 |> ignore;
  close_in_noerr ic;
  Sys.remove path

let workloads =
  [
    {
      label = "W1_sleep_100x50ms";
      jobs = 100;
      run = (fun _ -> Unix.sleepf 0.050);
    };
    {
      label = "W2_mixed_50sleep_50cpu";
      jobs = 100;
      run =
        (fun i ->
          if i < 50 then Unix.sleepf 0.050 else cpu_for_ms 5);
    };
    { label = "W3_syscall_100"; jobs = 100; run = syscall_heavy };
  ]

let run_candidate candidate workload =
  let semaphore = Eio.Semaphore.make candidate.max_threads in
  let samples = ref [] in
  let monitor_running = ref true in
  C.run_eio @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  Eio.Fiber.fork ~sw (fun () ->
      while !monitor_running do
        let threads = Option.value (C.thread_count ()) ~default:0 in
        let rss_kb = Option.value (C.rss_kb ()) ~default:0 in
        samples := { threads; rss_kb } :: !samples;
        Eio_unix.sleep 0.001
      done);
  let result, heartbeat, elapsed_us =
    C.with_heartbeat (fun () ->
        let promises =
          List.init workload.jobs (fun i ->
              Eio.Fiber.fork_promise ~sw (fun () ->
                  Eio.Semaphore.acquire semaphore;
                  Fun.protect
                    ~finally:(fun () -> Eio.Semaphore.release semaphore)
                    (fun () ->
                      Eio_unix.run_in_systhread
                        ~label:("default_probe." ^ workload.label)
                        (fun () -> workload.run i))))
        in
        List.iter Eio.Promise.await_exn promises)
  in
  monitor_running := false;
  Eio.Fiber.yield ();
  let recovery_started = C.now_us () in
  let rec wait_recovery attempts =
    if attempts = 0 then C.now_us () - recovery_started
    else
      let before = C.now_us () in
      Eio_unix.sleep 0.001;
      let delay = C.now_us () - before - 1000 in
      if delay < 2_000 then C.now_us () - recovery_started
      else wait_recovery (attempts - 1)
  in
  let recovery_us = wait_recovery 100 in
  let peak_threads =
    !samples |> List.map (fun s -> s.threads) |> C.max_opt |> Option.value ~default:0
  in
  let peak_rss_kb =
    !samples |> List.map (fun s -> s.rss_kb) |> C.max_opt |> Option.value ~default:0
  in
  let verdict = match result with Ok () -> "ok" | Error _ -> "error" in
  C.print_summary "default_thread_probe"
    ([
       ("candidate", candidate.label);
       ("max_threads", string_of_int candidate.max_threads);
       ("workload", workload.label);
       ("jobs", string_of_int workload.jobs);
       ("verdict", verdict);
       ("elapsed_us", string_of_int elapsed_us);
       ("peak_threads", string_of_int peak_threads);
       ("peak_rss_kb", string_of_int peak_rss_kb);
       ("recovery_us", string_of_int recovery_us);
     ]
    @ C.latency_fields "heartbeat" heartbeat)

let () =
  List.iter
    (fun candidate ->
      List.iter (run_candidate candidate) workloads)
    (candidates ())

