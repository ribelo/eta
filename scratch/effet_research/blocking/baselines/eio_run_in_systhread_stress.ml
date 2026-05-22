module C = Blocking_research_common

let run_case ~sw count delay =
  let before_threads = C.thread_count () |> Option.value ~default:(-1) in
  let before_rss = C.rss_kb () |> Option.value ~default:(-1) in
  let result, heartbeat, elapsed_us =
    C.with_heartbeat (fun () ->
        ignore
          (C.run_many ~sw count (fun _ ->
               Eio_unix.run_in_systhread ~label:"stress.sleep" (fun () ->
                   C.sleep_blocking delay))))
  in
  let after_threads = C.thread_count () |> Option.value ~default:(-1) in
  let after_rss = C.rss_kb () |> Option.value ~default:(-1) in
  C.print_summary "eio_run_in_systhread_stress"
    ([
       ("jobs", string_of_int count);
       ("delay_ms", string_of_int (int_of_float (delay *. 1000.0)));
       ("verdict", match result with Ok () -> "ok" | Error (exn, _) -> Printexc.to_string exn);
       ("elapsed_us", string_of_int elapsed_us);
       ("threads_before", string_of_int before_threads);
       ("threads_after", string_of_int after_threads);
       ("rss_before_kb", string_of_int before_rss);
       ("rss_after_kb", string_of_int after_rss);
     ]
    @ C.latency_fields "heartbeat" heartbeat)

let () =
  C.run_eio @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  List.iter
    (fun count -> run_case ~sw count 0.002)
    [ 10; 100; 1000 ]

