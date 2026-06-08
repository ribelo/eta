module C = Blocking_research_common
module Pool = Blocking_research_pool
open Effet

let config =
  {
    Pool.max_threads = 1;
    max_queued = 1;
    idle_timeout = 30.0;
    shutdown_timeout = Some 1.0;
    queue_policy = Reject;
  }

let () =
  C.run_eio @@ fun () ->
  let pool = Pool.create ~name:"worker_nested" config in
let result =
  Pool.submit ~label:"worker.nested" pool
    (fun () ->
        let nested_pool = Pool.create ~name:"nested_from_worker" config in
        Pool.submit ~label:"nested" nested_pool (fun () -> 1) ())
    ()
  in
  C.print_summary "worker_calls_nested_blocking"
    [ ("observed", match result with Ok (Ok n) -> "nested_ok:" ^ string_of_int n | Ok (Error e) -> Pool.string_of_error e | Error e -> Pool.string_of_error e); ("contract", "reject_or_undefined_in_v1") ]
