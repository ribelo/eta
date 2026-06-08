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
  let pool = Pool.create ~name:"worker_eio_stream" config in
  let stream = Eio.Stream.create 1 in
  let result =
    Pool.submit ~label:"worker.eio_stream" pool
      (fun () ->
        Eio.Stream.add stream 1;
        "added")
      ()
  in
  C.print_summary "worker_calls_eio_stream_add"
    [ ("observed", match result with Ok v -> v | Error e -> Pool.string_of_error e); ("contract", "unsupported_in_v1") ]

