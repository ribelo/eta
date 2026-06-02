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
  with_logger @@ fun _sw rt logger ->
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
  with_logger @@ fun _sw rt logger ->
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
        {
          primary = Cause.Fail "body";
          finalizer = Cause.Finalizer.Fail "<typed failure>";
        }) ->
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
  check_exit_error string_cause "release failure"
    (Cause.Finalizer (Cause.Finalizer.Fail "<typed failure>"))
    (Runtime.run rt eff)

let test_acquire_release_releases_on_defect () =
  with_runtime @@ fun rt ->
  let released = ref false in
  let eff =
    Effect.scoped
      (Effect.acquire_release ~acquire:(Effect.pure ())
         ~release:(fun () -> Effect.sync (fun () -> released := true))
      |> Effect.bind (fun () -> Effect.sync (fun () -> failwith "body defect")))
  in
  (match Runtime.run rt eff with
  | Exit.Error (Cause.Die _) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected body defect, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause
  | Exit.Ok _ -> Alcotest.fail "expected body defect");
  Alcotest.(check bool) "released" true !released

let test_acquire_release_suppresses_release_failure_after_defect () =
  with_runtime @@ fun rt ->
  let eff =
    Effect.scoped
      (Effect.acquire_release ~acquire:(Effect.pure ())
         ~release:(fun () -> Effect.fail "release")
      |> Effect.bind (fun () -> Effect.sync (fun () -> failwith "body defect")))
  in
  match Runtime.run rt eff with
  | Exit.Error
      (Cause.Suppressed
        { primary = Cause.Die _; finalizer = Cause.Finalizer.Fail "<typed failure>" }) ->
      ()
  | Exit.Error cause ->
      Alcotest.failf "expected suppressed release failure after defect, got %a"
        (Cause.pp Format.pp_print_string) cause
  | Exit.Ok _ -> Alcotest.fail "expected suppressed release failure after defect"

let test_acquire_use_release_success () =
  with_runtime @@ fun rt ->
  let trail = ref [] in
  let mark name = Effect.named name (Effect.sync (fun () -> trail := name :: !trail)) in
  let eff =
    Effect.scoped
      (Effect.acquire_use_release
         ~acquire:(mark "acquired" |> Effect.map (fun () -> 1))
         ~release:(fun resource ->
           mark ("released:" ^ string_of_int resource))
         (fun resource ->
           let open Syntax in
           let@ value = fun k -> k resource in
           mark ("body:" ^ string_of_int value)
           |> Effect.map (fun () -> value + 1)))
  in
  Alcotest.(check int) "body result" 2 (run_ok rt eff);
  Alcotest.(check (list string))
    "ordering"
    [ "acquired"; "body:1"; "released:1" ]
    (List.rev !trail)

let test_acquire_use_release_is_lexical_bracket () =
  with_runtime @@ fun rt ->
  let active = ref 0 in
  let max_active = ref 0 in
  let acquire =
    Effect.sync (fun () ->
        incr active;
        max_active := max !max_active !active;
        ())
  in
  let release () = Effect.sync (fun () -> decr active) in
  let one =
    Effect.acquire_use_release ~acquire ~release (fun () ->
        Effect.sync (fun () ->
            Alcotest.(check int) "active inside body" 1 !active))
  in
  run_ok rt (Effect.concat [ one; one; one ]);
  Alcotest.(check int) "released after each body" 0 !active;
  Alcotest.(check int) "no accumulated resources" 1 !max_active

let test_acquire_use_release_typed_failure_releases () =
  with_runtime @@ fun rt ->
  let released = ref false in
  let eff =
    Effect.scoped
      (Effect.acquire_use_release ~acquire:(Effect.pure "resource")
         ~release:(fun _ ->
           Effect.sync (fun () -> released := true))
         (fun _ -> Effect.fail `Boom))
  in
  (match Runtime.run rt eff with
  | Exit.Error (Cause.Fail `Boom) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected typed failure, got %a"
        (Cause.pp (fun fmt `Boom -> Format.pp_print_string fmt "Boom"))
        cause
  | Exit.Ok _ -> Alcotest.fail "expected typed failure");
  Alcotest.(check bool) "released" true !released

let test_acquire_use_release_defect_releases () =
  with_runtime @@ fun rt ->
  let released = ref false in
  let eff =
    Effect.scoped
      (Effect.acquire_use_release ~acquire:(Effect.pure "resource")
         ~release:(fun _ -> Effect.sync (fun () -> released := true))
         (fun _ -> Effect.sync (fun () -> failwith "body defect")))
  in
  (match Runtime.run rt eff with
  | Exit.Error (Cause.Die _) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected body defect, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause
  | Exit.Ok _ -> Alcotest.fail "expected body defect");
  Alcotest.(check bool) "released" true !released

let test_acquire_use_release_suppresses_release_failure_after_defect () =
  with_runtime @@ fun rt ->
  let eff =
    Effect.scoped
      (Effect.acquire_use_release ~acquire:(Effect.pure ())
         ~release:(fun () -> Effect.fail "release")
         (fun () -> Effect.sync (fun () -> failwith "body defect")))
  in
  match Runtime.run rt eff with
  | Exit.Error
      (Cause.Suppressed
        { primary = Cause.Die _; finalizer = Cause.Finalizer.Fail "<typed failure>" }) ->
      ()
  | Exit.Error cause ->
      Alcotest.failf "expected suppressed release failure after defect, got %a"
        (Cause.pp Format.pp_print_string) cause
  | Exit.Ok _ -> Alcotest.fail "expected suppressed release failure after defect"

let test_acquire_use_release_releases_on_cancel () =
  with_test_clock @@ fun sw clock rt ->
  let released = ref 0 in
  let acquired, acquired_u = Eio.Promise.create () in
  let slow =
    Effect.scoped
      (Effect.acquire_use_release
         ~acquire:
           (Effect.named "acquire_use_release.acquire.cancelled" (Effect.sync (fun () ->
                Eio.Promise.resolve acquired_u ())))
         ~release:(fun () ->
           Effect.named "acquire_use_release.release.cancelled"
             (Effect.sync (fun () -> incr released)))
         (fun () ->
           Effect.pure "slow" |> Effect.delay (Duration.seconds 10)))
  in
  let fast =
    Effect.named "wait-acquire-use-release-acquired"
      (Effect.sync (fun () -> Eio.Promise.await acquired))
    |> Effect.map (fun () -> "fast")
  in
  let promise = fork_run sw rt (Effect.race [ slow; fast ]) in
  wait_for_sleepers clock 2;
  check_exit_ok Alcotest.string "fast wins" "fast" (Eio.Promise.await promise);
  Alcotest.(check int) "cancelled release once" 1 !released

let test_acquire_use_release_release_failure_after_success () =
  with_runtime @@ fun rt ->
  let eff =
    Effect.scoped
      (Effect.acquire_use_release ~acquire:(Effect.pure ())
         ~release:(fun () -> Effect.fail "release")
         (fun () -> Effect.pure "body"))
  in
  check_exit_error string_cause "release failure"
    (Cause.Finalizer (Cause.Finalizer.Fail "<typed failure>"))
    (Runtime.run rt eff)

let test_acquire_release_finalizers_run_lifo_sequentially () =
  with_runtime @@ fun rt ->
  let a_started = Atomic.make false in
  let b_started = Atomic.make false in
  let trail = ref [] in
  let resource release =
    Effect.acquire_release ~acquire:Effect.unit ~release:(fun () ->
        Effect.sync release)
  in
  let a =
    resource (fun () ->
        Atomic.set a_started true;
        trail := "a" :: !trail)
  in
  let b =
    resource (fun () ->
        Atomic.set b_started true;
        trail := "b" :: !trail)
  in
  let c =
    resource (fun () ->
        Eio.Fiber.yield ();
        Alcotest.(check bool) "a not started before c finishes" false
          (Atomic.get a_started);
        Alcotest.(check bool) "b not started before c finishes" false
          (Atomic.get b_started);
        trail := "c" :: !trail)
  in
  let eff =
    Effect.scoped (Effect.concat [ a; b; c ] |> Effect.map (fun _ -> ()))
  in
  run_ok rt eff;
  Alcotest.(check (list string)) "lifo order" [ "c"; "b"; "a" ]
    (List.rev !trail)

let test_acquire_release_finalizer_failure_keeps_running_lifo () =
  with_runtime @@ fun rt ->
  let trail = ref [] in
  let resource release =
    Effect.acquire_release ~acquire:Effect.unit ~release:(fun () ->
        Effect.sync release)
  in
  let eff =
    Effect.scoped
      (Effect.concat
         [
           resource (fun () -> trail := "a" :: !trail);
           resource (fun () ->
               trail := "b" :: !trail;
               failwith "b release");
           resource (fun () ->
               trail := "c" :: !trail;
               failwith "c release");
         ])
  in
  (match Runtime.run rt eff with
  | Exit.Error
      (Cause.Finalizer
        (Cause.Finalizer.Sequential
          [ Cause.Finalizer.Die _; Cause.Finalizer.Die _ ])) ->
      ()
  | Exit.Error cause ->
      Alcotest.failf "expected sequential finalizer failures, got %a"
        (Cause.pp Format.pp_print_string) cause
  | Exit.Ok () -> Alcotest.fail "expected finalizer failures");
  Alcotest.(check (list string)) "all finalizers ran" [ "c"; "b"; "a" ]
    (List.rev !trail)

let test_repeat_releases_resources_each_iteration () =
  with_runtime @@ fun rt ->
  let active = ref 0 in
  let max_active = ref 0 in
  let acquire =
    Effect.sync (fun () ->
        incr active;
        max_active := max !max_active !active)
  in
  let release () = Effect.sync (fun () -> decr active) in
  let eff =
    Effect.repeat (Schedule.recurs 2)
      (Effect.acquire_release ~acquire ~release)
  in
  run_ok rt eff;
  Alcotest.(check int) "released at end" 0 !active;
  Alcotest.(check int) "one live resource per iteration" 1 !max_active

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

let rec typed_timeout_cause_contains_body_failure = function
  | Cause.Fail `Body -> true
  | Cause.Fail (`Slow | `Inner | `Outer) | Cause.Die _ | Cause.Interrupt _ ->
      false
  | Cause.Sequential causes | Cause.Concurrent causes ->
      List.exists typed_timeout_cause_contains_body_failure causes
  | Cause.Finalizer _ -> false
  | Cause.Suppressed { primary; finalizer } ->
      ignore finalizer;
      typed_timeout_cause_contains_body_failure primary

let test_effect_timeout_as_preserves_simultaneous_body_failure () =
  with_test_clock @@ fun sw clock rt ->
  let eff : (unit, [ `Slow | `Body ]) Effect.t =
    Effect.fail `Body
    |> Effect.delay (Duration.seconds 5)
    |> Effect.uninterruptible
    |> Effect.timeout_as (Duration.seconds 5) ~on_timeout:`Slow
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.seconds 5);
  match Eio.Promise.await promise with
  | Exit.Error cause ->
      if not (typed_timeout_cause_contains_body_failure cause) then
        Alcotest.failf "expected body failure in cause, got %a"
          (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
          cause
  | Exit.Ok _ -> Alcotest.fail "expected simultaneous timeout/body failure"

let test_effect_timeout_as_preserves_cancelled_body_finalizer_failure () =
  with_test_clock @@ fun sw clock rt ->
  let released = ref false in
  let eff : (unit, [ `Slow | `Release ]) Effect.t =
    Effect.scoped
      (Effect.acquire_release ~acquire:Effect.unit
         ~release:(fun () ->
           released := true;
           Effect.fail `Release)
      |> Effect.bind (fun () ->
             Effect.delay (Duration.seconds 10) Effect.unit))
    |> Effect.timeout_as (Duration.seconds 5) ~on_timeout:`Slow
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.seconds 5);
  match Eio.Promise.await promise with
  | Exit.Error cause ->
      check_string_cause_contains "timeout failure observed" "slow"
        (Cause.map (function `Slow -> "slow" | `Release -> "release") cause);
      check_suppressed_finalizer
        "cancelled body finalizer failure is preserved" "<typed failure>" cause;
      Alcotest.(check bool) "release ran before timeout returned" true !released
  | Exit.Ok _ -> Alcotest.fail "expected timeout/finalizer failure"

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

(* P1: Runtime.drain causes 100% CPU busy-wait.
   drain() uses a tight yield() loop while waiting for daemon fibers.
   This burns a full CPU core instead of efficiently sleeping.
   The test measures CPU time consumed during drain vs wall time.
   A correct implementation should use near-zero CPU while waiting;
   the busy-wait consumes ~100% of one core. *)

let test_drain_does_not_busy_wait () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
  in
  (* Launch a daemon that sleeps for 100ms *)
  let daemon_body =
    Effect.sync (fun () -> Eio_unix.sleep 0.1)
  in
  (match Runtime.run rt (Effect.Private.daemon daemon_body) with
  | Exit.Ok () -> ()
  | _ -> Alcotest.fail "daemon launch failed");
  (* Measure CPU time consumed during drain *)
  let cpu_before = Sys.time () in
  let wall_before = Unix.gettimeofday () in
  Runtime.drain rt;
  let cpu_after = Sys.time () in
  let wall_after = Unix.gettimeofday () in
  let cpu_ms = (cpu_after -. cpu_before) *. 1000.0 in
  let wall_ms = (wall_after -. wall_before) *. 1000.0 in
  (* Wall time should be ~100ms (waiting for daemon to finish).
     CPU time should be near 0 if drain sleeps properly.
     With busy-wait, CPU time ≈ wall time (100ms of spinning).
     Allow 10ms as threshold — anything above means busy-waiting. *)
  Alcotest.(check bool)
    (Printf.sprintf
       "drain should not busy-wait (CPU: %.1fms during %.1fms wall)"
       cpu_ms wall_ms)
    true (cpu_ms < 10.0)
