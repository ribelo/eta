module C = Blocking_research_common

let () =
  C.run_eio @@ fun () ->
  let result, heartbeat, elapsed_us =
    C.with_heartbeat (fun () ->
        Eio_unix.run_in_systhread ~label:"smoke.sleep" (fun () ->
            C.sleep_blocking 0.050))
  in
  C.print_summary "eio_run_in_systhread_smoke"
    ([
       ("verdict", match result with Ok () -> "ok" | Error (exn, _) -> Printexc.to_string exn);
       ("elapsed_us", string_of_int elapsed_us);
       ("threads", string_of_int (C.thread_count () |> Option.value ~default:(-1)));
     ]
    @ C.latency_fields "heartbeat" heartbeat)

