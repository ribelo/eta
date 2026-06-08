module C = Blocking_research_common
module Stub = Blocking_research_c_stubs

let run_domain label f =
  C.run_eio @@ fun () ->
  let finished = Atomic.make false in
  let domain =
    Domain.spawn (fun () ->
        let result =
          try Ok (f ())
          with exn -> Error (Printexc.to_string exn)
        in
        Atomic.set finished true;
        result)
  in
  let result, heartbeat, elapsed_us =
    C.with_heartbeat (fun () ->
        while not (Atomic.get finished) do
          Eio_unix.sleep 0.001
        done;
        ignore (Domain.join domain))
  in
  C.print_summary "domain_pool_hold_lock_positive"
    ([
       ("variant", label);
       ("verdict", match result with Ok () -> "ok" | Error (exn, _) -> Printexc.to_string exn);
       ("elapsed_us", string_of_int elapsed_us);
     ]
    @ C.latency_fields "heartbeat" heartbeat)

let () =
  run_domain "hold_lock_sleep" (fun () -> Stub.hold_lock_sleep 0.050);
  run_domain "hold_lock_cpu" (fun () -> ignore (Stub.hold_lock_cpu 60_000_000))

