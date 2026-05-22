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
  let pool = Pool.create ~name:"worker_promise" config in
  let promise, resolver = Eio.Promise.create () in
  let result =
    Pool.submit ~label:"worker.promise" pool
      (fun () ->
        Eio.Promise.resolve resolver "resolved";
        "worker_returned")
      ()
  in
  let observed =
    match result with
    | Ok v -> v ^ ":" ^ Eio.Promise.await promise
    | Error e -> Pool.string_of_error e
  in
  C.print_summary "worker_resolves_parent_promise"
    [ ("observed", observed); ("contract", "unsupported_in_v1") ]

