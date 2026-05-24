open Eta
open Eta_test
open Test_eta_support

let test_acquire_release () =
  with_runtime @@ fun rt ->
  let trail = ref [] in
  let mark name = Effect.named name (Effect.sync (fun () -> trail := name :: !trail)) in
  let eff =
    Effect.scoped
      (Effect.acquire_release
         ~acquire:(mark "acquired" |> Effect.map (fun () -> 1))
         ~release:(fun _ -> mark "released")
      |> Effect.bind (fun _ -> mark "body"))
  in
  run_ok rt eff;
  Alcotest.(check (list string))
    "ordering" [ "acquired"; "body"; "released" ] (List.rev !trail)

let test_acquire_release_root_scope_runs_finalizer () =
  with_runtime @@ fun rt ->
  let released = ref false in
  let eff =
    Effect.acquire_release ~acquire:Effect.unit
      ~release:(fun () -> Effect.sync (fun () -> released := true))
  in
  run_ok rt eff;
  Alcotest.(check bool) "released" true !released

let test_acquire_release_root_scope_runs_finalizer_on_failure () =
  with_runtime @@ fun rt ->
  let released = ref false in
  let eff =
    Effect.acquire_release ~acquire:Effect.unit
      ~release:(fun () -> Effect.sync (fun () -> released := true))
    |> Effect.bind (fun () -> Effect.fail `Boom)
  in
  (match Runtime.run rt eff with
  | Exit.Error (Cause.Fail `Boom) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected typed failure, got %a"
        (Cause.pp (fun fmt `Boom -> Format.pp_print_string fmt "Boom"))
        cause
  | Exit.Ok () -> Alcotest.fail "expected typed failure");
  Alcotest.(check bool) "released" true !released

let test_daemon_drains_acquire_release_finalizer () =
  with_runtime @@ fun rt ->
  let released = Atomic.make false in
  let daemon_body =
    Effect.acquire_release ~acquire:Effect.unit
      ~release:(fun () -> Effect.sync (fun () -> Atomic.set released true))
  in
  run_ok rt (Effect.Private.daemon daemon_body);
  Runtime.drain rt;
  Alcotest.(check bool) "released" true (Atomic.get released)

let test_daemon_failure_logs_diagnostic () =
  Eta_test.with_logger @@ fun _sw rt logger ->
  let daemon_body = Effect.sync (fun () -> failwith "daemon crash") in
  run_ok rt (Effect.Private.daemon daemon_body);
  Runtime.drain rt;
  match Logger.dump logger with
  | [ record ] ->
      Alcotest.(check bool) "level" true (record.level = Logger.Error);
      Alcotest.(check string) "body" "eta.daemon.failure" record.body;
      Alcotest.(check (option string))
        "exception message" (Some "Failure(\"daemon crash\")")
        (List.assoc_opt "exception.message" record.attrs)
  | records ->
      Alcotest.failf "expected one daemon diagnostic, got %d"
        (List.length records)

let test_daemon_interrupt_does_not_log_diagnostic () =
  Eta_test.with_logger @@ fun _sw rt logger ->
  let daemon_body =
    Effect.sync (fun () ->
        raise (Eio.Cancel.Cancelled (Failure "daemon shutdown")))
  in
  run_ok rt (Effect.Private.daemon daemon_body);
  Runtime.drain rt;
  Alcotest.(check int)
    "no daemon diagnostics" 0
    (List.length (Logger.dump logger))

let test_acquire_release_on_failure () =
  with_runtime @@ fun rt ->
  let trail = ref [] in
  let mark name = Effect.named name (Effect.sync (fun () -> trail := name :: !trail)) in
  let eff =
    Effect.scoped
      (Effect.acquire_release ~acquire:(mark "acq") ~release:(fun () ->
           mark "rel")
      |> Effect.bind (fun () -> Effect.fail `Boom)
      |> Effect.catch (fun (`Boom : [ `Boom ]) -> mark "caught"))
  in
  run_ok rt eff;
  Alcotest.(check (list string))
    "release after recovered body failure"
    [ "acq"; "caught"; "rel" ] (List.rev !trail)

let test_acquire_release_suppresses_release_failure () =
  with_runtime @@ fun rt ->
  let eff =
    Effect.scoped
      (Effect.acquire_release ~acquire:(Effect.pure ())
         ~release:(fun () -> Effect.fail "release")
      |> Effect.bind (fun () -> Effect.fail "body"))
  in
  match Runtime.run rt eff with
  | Exit.Error
      (Cause.Suppressed
        { primary = Cause.Fail "body"; finalizer = Cause.Fail "release" }) ->
      ()
  | Exit.Error cause ->
      Alcotest.failf "expected suppressed release failure, got %a"
        (Cause.pp Format.pp_print_string) cause
  | Exit.Ok () -> Alcotest.fail "expected suppressed release failure"

let test_acquire_release_release_failure_after_success () =
  with_runtime @@ fun rt ->
  let eff =
    Effect.scoped
      (Effect.acquire_release ~acquire:(Effect.pure ())
         ~release:(fun () -> Effect.fail "release")
      |> Effect.bind (fun () -> Effect.pure "body"))
  in
  check_exit_error string_cause "release failure" (Cause.Fail "release")
    (Runtime.run rt eff)

let test_effect_timeout_uses_virtual_clock () =
  with_test_clock @@ fun sw clock rt ->
  let eff =
    Effect.pure "done"
    |> Effect.delay (Duration.seconds 10)
    |> Effect.timeout (Duration.seconds 5)
    |> Effect.catch (fun (`Timeout : [ `Timeout ]) -> Effect.pure "timeout")
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.seconds 5);
  check_exit_ok Alcotest.string "timed out" "timeout"
    (Eio.Promise.await promise)

let test_effect_timeout_allows_fast_success () =
  with_test_clock @@ fun sw clock rt ->
  let eff =
    Effect.pure "done"
    |> Effect.delay (Duration.seconds 2)
    |> Effect.timeout (Duration.seconds 5)
    |> Effect.catch (fun (`Timeout : [ `Timeout ]) -> Effect.pure "timeout")
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.seconds 2);
  check_exit_ok Alcotest.string "completed" "done"
    (Eio.Promise.await promise)

let test_effect_timeout_preserves_user_timeout_failure () =
  with_test_clock @@ fun sw clock rt ->
  let eff =
    Effect.par
      (Effect.fail `Timeout |> Effect.delay (Duration.seconds 1))
      (Effect.delay (Duration.seconds 10) Effect.unit)
    |> Effect.timeout (Duration.seconds 5)
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 3;
  Test_clock.adjust clock (Duration.seconds 1);
  match Eio.Promise.await promise with
  | Exit.Error (Cause.Concurrent causes) ->
      Alcotest.(check bool)
        "body timeout preserved"
        true
        (List.exists
           (function Cause.Fail `Timeout -> true | _ -> false)
           causes);
      Alcotest.(check bool)
        "timer branch was only interrupted"
        true
        (List.exists Cause.is_interrupt_only causes)
  | Exit.Error (Cause.Fail `Timeout) ->
      Alcotest.fail "user Timeout was collapsed into timer Timeout"
  | Exit.Error cause ->
      Alcotest.failf "expected preserved user Timeout, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause
  | Exit.Ok _ -> Alcotest.fail "expected user Timeout failure"

let test_effect_timeout_nested_cancel_maps_to_outer_timeout () =
  with_test_clock @@ fun sw clock rt ->
  let inner =
    Effect.pure "done"
    |> Effect.delay (Duration.seconds 10)
    |> Effect.timeout (Duration.seconds 10)
  in
  let eff =
    inner
    |> Effect.timeout (Duration.seconds 5)
    |> Effect.catch (fun (`Timeout : [ `Timeout ]) ->
           Effect.fail `Total_timeout)
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 3;
  Test_clock.adjust clock (Duration.seconds 5);
  match Eio.Promise.await promise with
  | Exit.Error (Cause.Fail `Total_timeout) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected mapped timeout, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause
  | Exit.Ok _ -> Alcotest.fail "expected mapped timeout"

type typed_timeout_err = [ `Slow | `Inner | `Outer ]

let test_effect_timeout_as_keeps_exact_error_row () =
  with_runtime @@ fun rt ->
  let eff : (string, [ `Slow ]) Effect.t =
    Effect.pure "ok"
    |> Effect.timeout_as (Duration.seconds 1) ~on_timeout:`Slow
  in
  Alcotest.(check string) "ok" "ok" (run_ok rt eff)

let test_effect_timeout_as_maps_delayed_effect () =
  with_test_clock @@ fun sw clock rt ->
  let eff : (string, typed_timeout_err) Effect.t =
    Effect.pure "done"
    |> Effect.delay (Duration.seconds 10)
    |> Effect.timeout_as (Duration.seconds 5) ~on_timeout:`Slow
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.seconds 5);
  match Eio.Promise.await promise with
  | Exit.Error (Cause.Fail `Slow) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected typed timeout, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause
  | Exit.Ok _ -> Alcotest.fail "expected typed timeout"

let test_effect_timeout_as_nested_cancel_maps_to_outer_timeout () =
  with_test_clock @@ fun sw clock rt ->
  let inner : (string, typed_timeout_err) Effect.t =
    Effect.pure "done"
    |> Effect.delay (Duration.seconds 10)
    |> Effect.timeout_as (Duration.seconds 10) ~on_timeout:`Inner
  in
  let eff =
    inner |> Effect.timeout_as (Duration.seconds 5) ~on_timeout:`Outer
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 3;
  Test_clock.adjust clock (Duration.seconds 5);
  match Eio.Promise.await promise with
  | Exit.Error (Cause.Fail `Outer) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected outer typed timeout, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause
  | Exit.Ok _ -> Alcotest.fail "expected outer typed timeout"
