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
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let pool = Pool.create ~name:"error_raise" config in
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let eff =
    run_pool_as_effect pool "blocking.raise" (fun () -> raise (Failure "legacy boom")) ()
  in
  let verdict =
    match Runtime.run rt eff with
    | Exit.Error (Cause.Die die)
      when String.contains (Printexc.to_string die.exn) 'b' ->
        "cause_die"
    | Exit.Error _ -> "other_error"
    | Exit.Ok _ -> "unexpected_ok"
  in
  C.print_summary "blocking_raises_exn" [ ("verdict", verdict) ]

