module Exit = Eta.Exit
module Cause = Eta.Cause

module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  module Helper = Eta_sql_driver.Make (struct
    type driver_error = string

    type error = [ `Driver of string | `Invalid_blocking_pool of string | `Timeout ]

    let map_error err = `Driver err
    let detach_started_error = `Invalid_blocking_pool "detach-started rejected"
  end)

let with_runtime f = B.with_runtime (fun _ctx rt -> f rt)

let rec wait_until ?(attempts = 200_000) label pred =
  if pred () then ()
  else if attempts <= 0 then Alcotest.failf "timed out waiting for %s" label
  else (
    B.yield ();
    Thread.yield ();
    wait_until ~attempts:(attempts - 1) label pred)

let pp_error ppf = function
  | `Driver err -> Format.fprintf ppf "Driver(%S)" err
  | `Invalid_blocking_pool message ->
      Format.fprintf ppf "Invalid_blocking_pool(%S)" message
  | `Timeout -> Format.pp_print_string ppf "Timeout"

let test_leased_blocking_rejects_detach_started_pool () =
  let module BP = Eta_blocking.Pool in
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
    B.run rt
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
  let started = Atomic.make false in
  let interrupted = Atomic.make false in
  let mutex = Mutex.create () in
  let condition = Condition.create () in
  let mark_interrupted () =
    Mutex.lock mutex;
    Atomic.set interrupted true;
    Condition.broadcast condition;
    Mutex.unlock mutex
  in
  let await_interrupted () =
    Mutex.lock mutex;
    Fun.protect
      ~finally:(fun () -> Mutex.unlock mutex)
      (fun () ->
        while not (Atomic.get interrupted) do
          Condition.wait condition mutex
        done)
  in
  B.with_test_clock @@ fun ctx clock rt ->
  let eff =
    Helper.leased_blocking_result_timeout ~timeout:(Eta.Duration.ms 5)
      ~on_timeout:`Timeout
      ~on_cancel:mark_interrupted
      (fun () ->
        Atomic.set started true;
        await_interrupted ();
        Error "interrupted")
  in
  let result = B.fork_run ctx rt eff in
  wait_until "blocking worker start" (fun () ->
      Atomic.get started || B.is_resolved result);
  Alcotest.(check bool) "blocking worker started" true (Atomic.get started);
  wait_until "timeout sleeper" (fun () ->
      B.sleeper_count clock > 0 || B.is_resolved result);
  B.adjust_clock clock (Eta.Duration.ms 5);
  match B.await result with
  | Exit.Error (Cause.Fail `Timeout) ->
      Alcotest.(check bool) "cancel hook called" true (Atomic.get interrupted)
  | Exit.Error cause ->
      Alcotest.failf "expected timeout, got %a" (Cause.pp pp_error) cause
  | Exit.Ok _ -> Alcotest.fail "expected timeout"

let tests =
  [
    ( "leased blocking",
      [
        Alcotest.test_case "rejects detach-started blocking pool" `Quick
          test_leased_blocking_rejects_detach_started_pool;
        Alcotest.test_case "timeout calls on_cancel" `Quick
          test_timed_leased_blocking_calls_on_cancel;
      ] );
  ]
end
