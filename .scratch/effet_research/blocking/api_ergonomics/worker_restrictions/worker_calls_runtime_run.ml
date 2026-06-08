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
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let pool = Pool.create ~name:"worker_runtime" config in
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let result =
    Pool.submit ~label:"worker.runtime_run" pool
      (fun () ->
        match Runtime.run rt (Effect.pure 1) with
        | Exit.Ok n -> n
        | Exit.Error _ -> -1)
      ()
  in
  C.print_summary "worker_calls_runtime_run"
    [ ("observed", match result with Ok n -> "ok:" ^ string_of_int n | Error e -> Pool.string_of_error e); ("contract", "unsupported_in_v1") ]

