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

type typed_error = Bad_input of int

let () =
  C.run_eio @@ fun () ->
  let pool = Pool.create ~name:"typed_result" config in
  let result =
    Pool.submit ~label:"typed.result" pool
      (fun n -> if n mod 2 = 0 then Ok (n / 2) else Error (Bad_input n))
      3
  in
  let verdict =
    match result with
    | Ok (Error (Bad_input 3)) -> "typed_error_preserved"
    | Ok (Error (Bad_input n)) -> "typed_error_other:" ^ string_of_int n
    | Ok (Ok _) -> "unexpected_ok"
    | Error e -> Pool.string_of_error e
  in
  C.print_summary "typed_errors_via_result" [ ("verdict", verdict) ]
