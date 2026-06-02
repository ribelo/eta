module Effect = Eta.Effect
module Runtime = Eta.Runtime
module Exit = Eta.Exit
module Cause = Eta.Cause

module Helper = Eta_sql_driver.Make (struct
  type driver_error = string

  type error = [ `Driver of string | `Invalid_blocking_pool of string | `Timeout ]

  let map_error err = `Driver err
  let detach_started_error = `Invalid_blocking_pool "detach-started rejected"
end)

let with_runtime f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  f rt

let pp_error ppf = function
  | `Driver err -> Format.fprintf ppf "Driver(%S)" err
  | `Invalid_blocking_pool message ->
      Format.fprintf ppf "Invalid_blocking_pool(%S)" message
  | `Timeout -> Format.pp_print_string ppf "Timeout"

let test_leased_blocking_rejects_detach_started_pool () =
  let module BP = Effect.Blocking.Pool in
  let blocking_pool =
    BP.create ~name:"sql-driver-detach"
      {
        max_threads = 1;
        max_queued = 0;
        queue_policy = BP.Reject;
        shutdown_policy = BP.Detach_started;
      }
  in
  with_runtime @@ fun rt ->
  match
    Runtime.run rt
      (Helper.leased_blocking_result ~blocking_pool (fun () -> Ok 1))
  with
  | Exit.Error (Cause.Fail (`Invalid_blocking_pool "detach-started rejected")) ->
      ()
  | Exit.Error cause ->
      Alcotest.failf "expected detach-started rejection, got %a"
        (Cause.pp pp_error)
        cause
  | Exit.Ok _ -> Alcotest.fail "expected detach-started rejection"

let test_timed_leased_blocking_calls_on_cancel () =
  let interrupted = Atomic.make false in
  with_runtime @@ fun rt ->
  let effect =
    Helper.leased_blocking_result_timeout ~timeout:(Eta.Duration.ms 5)
      ~on_timeout:`Timeout
      ~on_cancel:(fun () -> Atomic.set interrupted true)
      (fun () ->
        while not (Atomic.get interrupted) do
          Unix.sleepf 0.001
        done;
        Error "interrupted")
  in
  match Runtime.run rt effect with
  | Exit.Error (Cause.Fail `Timeout) ->
      Alcotest.(check bool) "cancel hook called" true (Atomic.get interrupted)
  | Exit.Error cause ->
      Alcotest.failf "expected timeout, got %a" (Cause.pp pp_error) cause
  | Exit.Ok _ -> Alcotest.fail "expected timeout"

let () =
  Alcotest.run "Eta SQL driver"
    [
      ( "leased blocking",
        [
          Alcotest.test_case "rejects detach-started blocking pool" `Quick
            test_leased_blocking_rejects_detach_started_pool;
          Alcotest.test_case "timeout calls on_cancel" `Quick
            test_timed_leased_blocking_calls_on_cancel;
        ] );
    ]
