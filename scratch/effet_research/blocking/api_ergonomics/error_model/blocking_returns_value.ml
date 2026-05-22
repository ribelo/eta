module C = Blocking_research_common
module Pool = Blocking_research_pool
open Effet

let config =
  {
    Pool.max_threads = 1;
    max_queued = 8;
    idle_timeout = 30.0;
    shutdown_timeout = Some 1.0;
    queue_policy = Wait;
  }

let run_pool_as_effect pool label f x =
  Effect.thunk label (fun () ->
      match Pool.submit ~label pool f x with
      | Ok value -> value
      | Error (Pool.Worker_raised (exn, bt)) -> Printexc.raise_with_backtrace exn bt
      | Error e -> failwith (Pool.string_of_error e))

let () =
  C.run_eio @@ fun () ->
  let pool = Pool.create ~name:"error_value" config in
  let result = Pool.submit ~label:"value" pool (fun n -> n + 1) 41 in
  C.print_summary "blocking_returns_value"
    [ ("verdict", match result with Ok 42 -> "ok" | Ok _ -> "wrong_value" | Error e -> Pool.string_of_error e) ]

