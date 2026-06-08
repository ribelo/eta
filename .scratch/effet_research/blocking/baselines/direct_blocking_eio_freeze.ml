module C = Blocking_research_common
module Stub = Blocking_research_c_stubs

let measure variant f =
  C.run_eio @@ fun () ->
  let result, heartbeat, elapsed_us = C.with_heartbeat f in
  C.print_summary "direct_blocking_eio_freeze"
    ([
       ("variant", variant);
       ("verdict", match result with Ok () -> "fail_control" | Error (exn, _) -> Printexc.to_string exn);
       ("elapsed_us", string_of_int elapsed_us);
     ]
    @ C.latency_fields "heartbeat" heartbeat)

let () =
  measure "unix_sleep" (fun () -> C.sleep_blocking 0.050);
  measure "release_lock_sleep" (fun () -> Stub.release_lock_sleep 0.050);
  measure "hold_lock_sleep" (fun () -> Stub.hold_lock_sleep 0.050)

