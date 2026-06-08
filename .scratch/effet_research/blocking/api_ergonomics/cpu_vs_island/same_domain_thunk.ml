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
  let result, heartbeat, elapsed_us =
    C.with_heartbeat (fun () -> ignore (List.map cpu_work items))
  in
  C.print_summary "cpu_same_domain_thunk"
    ([
       ("items", string_of_int (List.length items));
       ("verdict", match result with Ok () -> "ok" | Error (exn, _) -> Printexc.to_string exn);
       ("elapsed_us", string_of_int elapsed_us);
     ]
    @ C.latency_fields "heartbeat" heartbeat)

