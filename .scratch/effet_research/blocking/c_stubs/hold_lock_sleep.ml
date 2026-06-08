module C = Blocking_research_common
module Stub = Blocking_research_c_stubs

let run_one mode f =
  C.run_eio @@ fun () ->
  let result, heartbeat, elapsed_us =
    C.with_heartbeat (fun () -> f ())
  in
  let verdict =
    match result with
    | Ok () -> "ok"
    | Error (exn, _) -> "error:" ^ Printexc.to_string exn
  in
  C.print_summary "hold_lock_sleep"
    ([
       ("mode", mode);
       ("verdict", verdict);
       ("elapsed_us", string_of_int elapsed_us);
     ]
    @ C.latency_fields "heartbeat" heartbeat)

let () =
  run_one "direct" (fun () -> Stub.hold_lock_sleep 0.050);
  run_one "run_in_systhread" (fun () ->
      Eio_unix.run_in_systhread ~label:"hold_lock_sleep" (fun () -> Stub.hold_lock_sleep 0.050))

