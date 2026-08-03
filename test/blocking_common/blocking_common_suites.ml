module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  open Eta

  module BP = Eta_blocking.Pool
  module E = Effect

  (* blockadm-5bnu *)
  let blocking_config ?(max_threads = 4) ?(max_queued = 64)
      ?(shutdown_policy = BP.Drain) () : BP.config =
    { max_threads; max_queued; shutdown_policy }

  let pp_hidden ppf _ = Format.pp_print_string ppf "<blocking>"

  let run_ok rt eff =
    match B.run rt eff with
    | Exit.Ok value -> value
    | Exit.Error cause ->
        Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause

  let check_exit_ok testable label expected = function
    | Exit.Ok actual -> Alcotest.check testable label expected actual
    | Exit.Error cause ->
        Alcotest.failf "%s: expected Ok, got %a" label
          (Cause.pp pp_hidden) cause

  let check_typed_failure label pred = function
    | Exit.Error (Cause.Fail err) when pred err -> ()
    | Exit.Error cause ->
        Alcotest.failf "%s: expected typed failure, got %a" label
          (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.failf "%s: expected typed failure, got Ok" label

  let contains_substring text needle =
    let text_len = String.length text in
    let needle_len = String.length needle in
    let rec loop index =
      index + needle_len <= text_len
      && (String.equal (String.sub text index needle_len) needle
         || loop (index + 1))
    in
    needle_len = 0 || loop 0

  let check_die_message label needle = function
    | Cause.Die die ->
        Alcotest.(check bool) label true
          (contains_substring (Printexc.to_string die.exn) needle)
    | cause ->
        Alcotest.failf "%s: expected Die, got %a" label (Cause.pp pp_hidden)
          cause

  let wait_until ?(attempts = 500) pred =
    let rec loop remaining =
      if pred () then ()
      else if remaining = 0 then Alcotest.fail "condition did not become true"
      else (
        B.yield ();
        Unix.sleepf 0.001;
        loop (remaining - 1))
    in
    loop attempts

  let now_us () = int_of_float (Unix.gettimeofday () *. 1_000_000.0)

  let elapsed_us f =
    let started = now_us () in
    let value = f () in
    (now_us () - started, value)

  (* blockadm-uazq *)
  let test_blocking_run_executes () =
    B.with_runtime @@ fun _ctx rt ->
    Alcotest.(check int) "result" 1
      (run_ok rt (Eta_blocking.run (fun () -> 1)))

  (* blockadm-8w9l blockadm-dc1z blockadm-jazl blockadm-43yc blockadm-69e5 *)
  let test_blocking_try_run_completes () =
    B.with_runtime @@ fun _ctx rt ->
    let pool = BP.create ~name:"try-completes" (blocking_config ()) in
    match B.run rt (Eta_blocking.try_run ~pool (fun () -> 42)) with
    | Exit.Ok (Eta_blocking.Completed value) ->
        Alcotest.(check int) "completed value" 42 value
    | Exit.Ok (Eta_blocking.Not_run _) -> Alcotest.fail "expected completion"
    | Exit.Error cause ->
        Alcotest.failf "expected completion, got %a" (Cause.pp pp_hidden) cause

  (* blockadm-2r7p blockadm-ycfp blockadm-taew blockadm-l8jp *)
  let test_blocking_try_run_reports_saturation_without_queueing () =
    B.with_runtime @@ fun ctx rt ->
    let pool =
      BP.create ~name:"try-saturated"
        (blocking_config ~max_threads:1 ~max_queued:1 ())
    in
    let first =
      B.fork_run ctx rt
        (Eta_blocking.run ~pool (fun () -> Unix.sleepf 0.060))
    in
    wait_until (fun () -> (BP.stats pool).active = 1);
    let callback_ran = Atomic.make false in
    (match
       B.run rt
         (Eta_blocking.try_run ~pool (fun () ->
              Atomic.set callback_ran true))
     with
    | Exit.Ok (Eta_blocking.Not_run Eta_blocking.Saturated) -> ()
    | Exit.Ok (Eta_blocking.Not_run Eta_blocking.Shutting_down) ->
        Alcotest.fail "expected saturation"
    | Exit.Ok (Eta_blocking.Completed ()) ->
        Alcotest.fail "saturated callback completed"
    | Exit.Error cause ->
        Alcotest.failf "expected saturation, got %a" (Cause.pp pp_hidden) cause);
    Alcotest.(check bool) "callback did not run" false (Atomic.get callback_ran);
    Alcotest.(check int) "not queued" 0 (BP.stats pool).queued;
    Alcotest.(check int) "rejected once" 1 (BP.stats pool).rejected;
    check_exit_ok Alcotest.unit "first" () (B.await first)

  (* blockadm-9t58 blockadm-86xw *)
  let test_blocking_run_and_stats () =
    B.with_runtime @@ fun _ctx rt ->
    let pool = BP.create ~name:"basic" (blocking_config ~max_threads:2 ()) in
    Alcotest.(check int) "first run" 42
      (run_ok rt (Eta_blocking.run ~pool ~name:"basic.answer" (fun () -> 42)));
    Alcotest.(check int) "second run" 43
      (run_ok rt (Eta_blocking.run ~pool ~name:"basic.second" (fun () -> 43)));
    let stats = BP.stats pool in
    Alcotest.(check int) "completed" 2 stats.completed;
    Alcotest.(check int) "active" 0 stats.active;
    Alcotest.(check int) "queued" 0 stats.queued

  (* blockadm-jqh0 blockadm-s15s blockadm-3yn4 *)
  let test_blocking_stats_separate_waiting_from_queue () =
    B.with_runtime @@ fun ctx rt ->
    let pool =
      BP.create ~name:"waiting-stats"
        (blocking_config ~max_threads:1 ~max_queued:0 ())
    in
    let first =
      B.fork_run ctx rt
        (Eta_blocking.run ~pool (fun () -> Unix.sleepf 0.060))
    in
    wait_until (fun () -> (BP.stats pool).active = 1);
    let second = B.fork_run ctx rt (Eta_blocking.run ~pool (fun () -> 2)) in
    wait_until (fun () -> (BP.stats pool).waiting = 1);
    let stats = BP.stats pool in
    Alcotest.(check int) "one waiter" 1 stats.waiting;
    Alcotest.(check int) "no queue entries" 0 stats.queued;
    check_exit_ok Alcotest.unit "first" () (B.await first);
    check_exit_ok Alcotest.int "second" 2 (B.await second);
    Alcotest.(check int) "waiting cleared" 0 (BP.stats pool).waiting

  (* blockadm-ov29 blockadm-609o blockadm-s15s *)
  let test_blocking_cancelled_admission_waiter_records_evidence () =
    B.with_runtime @@ fun ctx rt ->
    let pool =
      BP.create ~name:"cancel-waiter"
        (blocking_config ~max_threads:1 ~max_queued:0 ())
    in
    let first =
      B.fork_run ctx rt
        (Eta_blocking.run ~pool (fun () -> Unix.sleepf 0.060))
    in
    wait_until (fun () -> (BP.stats pool).active = 1);
    let callback_ran = Atomic.make false in
    let waiter =
      B.fork_run_cancelable ctx rt
        (Eta_blocking.run ~pool (fun () -> Atomic.set callback_ran true))
    in
    wait_until (fun () -> (BP.stats pool).waiting = 1);
    B.cancel_fiber waiter;
    (match B.await_cancelable waiter with
    | `Cancelled -> ()
    | `Returned (Exit.Error cause) ->
        Alcotest.(check bool) "waiter interruption" true
          (Cause.is_interrupt_only cause)
    | `Returned (Exit.Ok ()) -> Alcotest.fail "expected cancellation");
    Alcotest.(check int) "waiting cleared" 0 (BP.stats pool).waiting;
    Alcotest.(check int) "cancellation recorded" 1
      (BP.stats pool).cancelled_before_start;
    Alcotest.(check bool) "callback did not run" false (Atomic.get callback_ran);
    check_exit_ok Alcotest.unit "first" () (B.await first)

  let test_blocking_result_lifts_result_value () =
    B.with_runtime @@ fun _ctx rt ->
    let ok =
      Eta_blocking.run_result ~name:"blocking.result.ok" (fun () -> Ok 7)
    in
    let err =
      Eta_blocking.run_result ~name:"blocking.result.err" (fun () -> Error `Bad)
    in
    Alcotest.(check int) "ok" 7 (run_ok rt ok);
    B.run rt err |> check_typed_failure "err" (( = ) `Bad)

  (* blockadm-3vwr blockadm-0cun *)
  let test_blocking_try_run_result_completes_ok () =
    B.with_runtime @@ fun _ctx rt ->
    match B.run rt (Eta_blocking.try_run_result (fun () -> Ok 7)) with
    | Exit.Ok (Eta_blocking.Completed value) ->
        Alcotest.(check int) "completed value" 7 value
    | Exit.Ok (Eta_blocking.Not_run _) -> Alcotest.fail "expected completion"
    | Exit.Error cause ->
        Alcotest.failf "expected completion, got %a" (Cause.pp pp_hidden) cause

  (* blockadm-ztyh *)
  let test_blocking_try_run_result_preserves_error () =
    B.with_runtime @@ fun _ctx rt ->
    B.run rt (Eta_blocking.try_run_result (fun () -> Error `Bad))
    |> check_typed_failure "try_run_result error" (( = ) `Bad)

  (* blockadm-mz5m *)
  let test_blocking_try_run_exception_is_defect () =
    B.with_runtime @@ fun _ctx rt ->
    let pool = BP.create ~name:"try-defect" (blocking_config ()) in
    let defect = Failure "try_run defect" in
    (match
       B.run rt
         (Eta_blocking.try_run ~pool (fun () ->
              (raise defect : int)))
     with
    | Exit.Error (Cause.Die die) when die.exn == defect -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected defect, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected defect");
    let stats = BP.stats pool in
    Alcotest.(check int) "defect released slot" 0 stats.active;
    Alcotest.(check int) "defect completed callback" 1 stats.completed

  let test_blocking_result_short_aliases () =
    B.with_runtime @@ fun _ctx rt ->
    Alcotest.(check int) "result alias" 7
      (run_ok rt
         (Eta_blocking.result ~name:"blocking.result.alias" (fun () -> Ok 7)));
    Alcotest.(check int) "result_timeout alias" 8
      (run_ok rt
         (Eta_blocking.result_timeout ~name:"blocking.result-timeout.alias"
            ~timeout:(Duration.ms 100) ~on_timeout:`Timeout (fun () -> Ok 8)))

  let test_blocking_result_exception_is_defect () =
    B.with_runtime @@ fun _ctx rt ->
    let pool = BP.create ~name:"blocking-result-defect" (blocking_config ()) in
    let defect = Failure "blocking result defect" in
    let eff =
      Eta_blocking.run_result ~pool ~name:"blocking.result.defect" (fun () ->
          (raise defect : (int, [ `Expected ]) result))
    in
    match B.run rt eff with
    | Exit.Error (Cause.Die die) when die.exn == defect -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected blocking exception to be a defect, got %a"
          (Cause.pp (fun fmt `Expected -> Format.pp_print_string fmt "expected"))
          cause
    | Exit.Ok value -> Alcotest.failf "expected blocking defect, got Ok %d" value

  let test_blocking_result_timeout_interrupts_and_fails_typed () =
    B.with_runtime @@ fun _ctx rt ->
    let interrupted = Atomic.make false in
    let eff =
      Eta_blocking.run_result_timeout ~name:"blocking.result.timeout"
        ~on_cancel:(fun () -> Atomic.set interrupted true)
        ~timeout:(Duration.ms 5) ~on_timeout:`Timeout (fun () ->
          Unix.sleepf 0.030;
          Ok 7)
    in
    B.run rt eff |> check_typed_failure "timeout" (( = ) `Timeout);
    Alcotest.(check bool) "on_cancel called" true (Atomic.get interrupted)

  let test_blocking_result_timeout_calls_on_cancel_once () =
    B.with_runtime @@ fun _ctx rt ->
    let pool =
      BP.create ~name:"blocking-result-timeout-once"
        (blocking_config ~max_threads:1 ())
    in
    let hook_calls = Atomic.make 0 in
    let finished = Atomic.make false in
    let eff =
      Eta_blocking.run_result_timeout ~pool ~name:"blocking.result.timeout-once"
        ~on_cancel:(fun () -> Atomic.incr hook_calls)
        ~timeout:(Duration.ms 5) ~on_timeout:`Timeout (fun () ->
          Unix.sleepf 0.030;
          Atomic.set finished true;
          Ok 7)
    in
    B.run rt eff |> check_typed_failure "timeout" (( = ) `Timeout);
    wait_until (fun () -> Atomic.get finished);
    Alcotest.(check int) "on_cancel calls" 1 (Atomic.get hook_calls)

  let test_blocking_result_timeout_bounds_started_drain_wait () =
    B.with_runtime @@ fun _ctx rt ->
    let pool =
      BP.create ~name:"blocking-result-timeout-started-drain"
        (blocking_config ~max_threads:1 ~max_queued:0 ~shutdown_policy:BP.Drain
           ())
    in
    let elapsed, exit =
      elapsed_us (fun () ->
          B.run rt
            (Eta_blocking.run_result_timeout ~pool
               ~name:"blocking.result.timeout-started-drain"
               ~timeout:(Duration.ms 10) ~on_timeout:`Timeout (fun () ->
                 Unix.sleepf 0.25;
                 Ok ())))
    in
    Alcotest.(check bool) "caller wait bounded" true (elapsed < 50_000);
    Alcotest.(check int) "started work remains active" 1 (BP.stats pool).active;
    exit |> check_typed_failure "timeout" (( = ) `Timeout);
    wait_until ~attempts:2_000 (fun () -> (BP.stats pool).completed = 1);
    Alcotest.(check int) "started work released" 0 (BP.stats pool).active

  let test_blocking_result_timeout_cancels_queued_work () =
    B.with_runtime @@ fun ctx rt ->
    let pool =
      BP.create ~name:"blocking-result-timeout-queued"
        (blocking_config ~max_threads:1 ~max_queued:1 ~shutdown_policy:BP.Drain
           ())
    in
    let blocker_done = Atomic.make false in
    let queued_ran = Atomic.make false in
    let blocker =
      B.fork_run ctx rt
        (Eta_blocking.run ~pool ~name:"blocking.result.timeout-queued.blocker"
           (fun () ->
             Unix.sleepf 0.10;
             Atomic.set blocker_done true))
    in
    wait_until (fun () -> (BP.stats pool).active = 1);
    let exit =
      B.run rt
        (Eta_blocking.run_result_timeout ~pool ~name:"blocking.result.timeout-queued"
           ~timeout:(Duration.ms 5) ~on_timeout:`Timeout (fun () ->
             Atomic.set queued_ran true;
             Ok ()))
    in
    exit |> check_typed_failure "timeout" (( = ) `Timeout);
    wait_until ~attempts:1_000 (fun () -> Atomic.get blocker_done);
    check_exit_ok Alcotest.unit "blocker" () (B.await blocker);
    B.yield ();
    Alcotest.(check bool) "queued job did not run" false
      (Atomic.get queued_ran);
    Alcotest.(check int) "queued job cancelled" 1
      (BP.stats pool).cancelled_before_start

  let test_blocking_started_cancellation_is_nonpreemptive () =
    B.with_runtime @@ fun _ctx rt ->
    let pool =
      BP.create ~name:"cancel-started" (blocking_config ~max_threads:1 ())
    in
    let completed = Atomic.make false in
    let elapsed, result =
      elapsed_us (fun () ->
          B.run rt
            (Eta_blocking.run ~pool ~name:"cancel-started.job"
               (fun () ->
                 Unix.sleepf 0.030;
                 Atomic.set completed true)
            |> E.timeout (Duration.ms 5)))
    in
    (match result with Exit.Ok _ | Exit.Error _ -> ());
    Alcotest.(check bool) "worker completed" true (Atomic.get completed);
    Alcotest.(check bool) "waited for started job" true (elapsed >= 25_000)

  (* blockadm-okes blockadm-8a7k *)
  let test_blocking_shutdown_interrupts_new_jobs () =
    B.with_runtime @@ fun _ctx rt ->
    let pool = BP.create ~name:"shutdown" (blocking_config ()) in
    run_ok rt (BP.shutdown pool);
    match
      B.run rt
        (Eta_blocking.run ~pool ~name:"after-shutdown" (fun () -> ()))
    with
    | Exit.Ok _ -> Alcotest.fail "expected shutdown interruption"
    | Exit.Error cause ->
        Alcotest.(check bool) "interruption" true
          (Cause.is_interrupt_only cause)

  (* blockadm-2qg5 blockadm-6nox blockadm-01e8 blockadm-680x *)
  let test_blocking_try_run_reports_shutdown () =
    B.with_runtime @@ fun _ctx rt ->
    let pool = BP.create ~name:"try-shutdown" (blocking_config ()) in
    run_ok rt (BP.shutdown pool);
    let callback_ran = Atomic.make false in
    (match
       B.run rt
         (Eta_blocking.try_run ~pool (fun () -> Atomic.set callback_ran true))
     with
    | Exit.Ok (Eta_blocking.Not_run Eta_blocking.Shutting_down) -> ()
    | Exit.Ok _ -> Alcotest.fail "expected Not_run Shutting_down"
    | Exit.Error cause ->
        Alcotest.failf "expected shutdown outcome, got %a" (Cause.pp pp_hidden)
          cause);
    let stats = BP.stats pool in
    Alcotest.(check bool) "callback did not run" false (Atomic.get callback_ran);
    Alcotest.(check int) "shutdown not rejected" 0 stats.rejected;
    Alcotest.(check int) "shutdown not cancelled" 0
      stats.cancelled_before_start

  let test_blocking_shutdown_drain_waits_for_started () =
    B.with_runtime @@ fun ctx rt ->
    let pool =
      BP.create ~name:"drain"
        (blocking_config ~max_threads:1 ~shutdown_policy:BP.Drain ())
    in
    let worker =
      B.fork_run ctx rt
        (Eta_blocking.run ~pool ~name:"drain.job" (fun () ->
             Unix.sleepf 0.030))
    in
    wait_until (fun () -> (BP.stats pool).active = 1);
    let elapsed, () = elapsed_us (fun () -> run_ok rt (BP.shutdown pool)) in
    Alcotest.(check bool) "drain waited" true (elapsed >= 20_000);
    check_exit_ok Alcotest.unit "worker" () (B.await worker)

  (* blockadm-2q6m blockadm-31qp *)
  let test_blocking_shutdown_drain_runs_queued_job () =
    B.with_runtime @@ fun ctx rt ->
    let pool =
      BP.create ~name:"drain-queued"
        (blocking_config ~max_threads:1 ~max_queued:1
           ~shutdown_policy:BP.Drain ())
    in
    let first =
      B.fork_run ctx rt
        (Eta_blocking.run ~pool (fun () -> Unix.sleepf 0.040))
    in
    wait_until (fun () -> (BP.stats pool).active = 1);
    let queued_ran = Atomic.make false in
    let queued =
      B.fork_run ctx rt
        (Eta_blocking.run ~pool (fun () -> Atomic.set queued_ran true))
    in
    wait_until (fun () -> (BP.stats pool).queued = 1);
    run_ok rt (BP.shutdown pool);
    check_exit_ok Alcotest.unit "first" () (B.await first);
    check_exit_ok Alcotest.unit "queued" () (B.await queued);
    Alcotest.(check bool) "queued callback ran" true (Atomic.get queued_ran)

  (* blockadm-cjsj *)
  let test_blocking_shutdown_detach_interrupts_queued_job () =
    B.with_runtime @@ fun ctx rt ->
    let pool =
      BP.create ~name:"detach-queued"
        (blocking_config ~max_threads:1 ~max_queued:1
           ~shutdown_policy:BP.Detach_started ())
    in
    let first =
      B.fork_run ctx rt
        (Eta_blocking.run ~pool (fun () -> Unix.sleepf 0.040))
    in
    wait_until (fun () -> (BP.stats pool).active = 1);
    let queued_ran = Atomic.make false in
    let queued =
      B.fork_run ctx rt
        (Eta_blocking.run ~pool (fun () -> Atomic.set queued_ran true))
    in
    wait_until (fun () -> (BP.stats pool).queued = 1);
    run_ok rt (BP.shutdown pool);
    (match B.await queued with
    | Exit.Error cause ->
        Alcotest.(check bool) "queued interruption" true
          (Cause.is_interrupt_only cause)
    | Exit.Ok () -> Alcotest.fail "expected queued interruption");
    Alcotest.(check bool) "queued callback did not run" false
      (Atomic.get queued_ran);
    ignore (B.await first : (unit, _) Exit.t)

  (* blockadm-pa7p *)
  let test_blocking_shutdown_drain_interrupts_admission_waiter () =
    B.with_runtime @@ fun ctx rt ->
    let pool =
      BP.create ~name:"drain-waiter"
        (blocking_config ~max_threads:1 ~max_queued:0
           ~shutdown_policy:BP.Drain ())
    in
    let first =
      B.fork_run ctx rt
        (Eta_blocking.run ~pool (fun () -> Unix.sleepf 0.040))
    in
    wait_until (fun () -> (BP.stats pool).active = 1);
    let waiter_ran = Atomic.make false in
    let waiter =
      B.fork_run ctx rt
        (Eta_blocking.run ~pool (fun () -> Atomic.set waiter_ran true))
    in
    wait_until (fun () -> (BP.stats pool).waiting = 1);
    run_ok rt (BP.shutdown pool);
    (match B.await waiter with
    | Exit.Error cause ->
        Alcotest.(check bool) "waiter interruption" true
          (Cause.is_interrupt_only cause)
    | Exit.Ok () -> Alcotest.fail "expected waiter interruption");
    Alcotest.(check bool) "waiter callback did not run" false
      (Atomic.get waiter_ran);
    Alcotest.(check int) "waiting cleared" 0 (BP.stats pool).waiting;
    check_exit_ok Alcotest.unit "first" () (B.await first)

  (* blockadm-17n6 *)
  let test_blocking_shutdown_detach_interrupts_admission_waiter () =
    B.with_runtime @@ fun ctx rt ->
    let pool =
      BP.create ~name:"detach-waiter"
        (blocking_config ~max_threads:1 ~max_queued:0
           ~shutdown_policy:BP.Detach_started ())
    in
    let first =
      B.fork_run ctx rt
        (Eta_blocking.run ~pool (fun () -> Unix.sleepf 0.040))
    in
    wait_until (fun () -> (BP.stats pool).active = 1);
    let waiter_ran = Atomic.make false in
    let waiter =
      B.fork_run ctx rt
        (Eta_blocking.run ~pool (fun () -> Atomic.set waiter_ran true))
    in
    wait_until (fun () -> (BP.stats pool).waiting = 1);
    run_ok rt (BP.shutdown pool);
    (match B.await waiter with
    | Exit.Error cause ->
        Alcotest.(check bool) "waiter interruption" true
          (Cause.is_interrupt_only cause)
    | Exit.Ok () -> Alcotest.fail "expected waiter interruption");
    Alcotest.(check bool) "waiter callback did not run" false
      (Atomic.get waiter_ran);
    Alcotest.(check int) "waiting cleared" 0 (BP.stats pool).waiting;
    ignore (B.await first : (unit, _) Exit.t)

  let test_blocking_worker_rejects_nested_run () =
    B.with_runtime @@ fun _ctx rt ->
    let pool = BP.create ~name:"worker-nested-run" (blocking_config ()) in
    match
      B.run rt
        (Eta_blocking.run ~pool ~name:"outer" (fun () ->
             ignore (Eta_blocking.run ~pool ~name:"inner" (fun () -> ()))))
    with
    | Exit.Ok _ -> Alcotest.fail "expected nested run failure"
    | Exit.Error cause -> check_die_message "nested run" "Eta_blocking.run" cause

  let test_blocking_worker_rejects_runtime_run () =
    B.with_runtime @@ fun _ctx rt ->
    let pool = BP.create ~name:"worker-runtime" (blocking_config ()) in
    match
      B.run rt
        (Eta_blocking.run ~pool ~name:"outer" (fun () -> ignore (B.run rt E.unit)))
    with
    | Exit.Ok _ -> Alcotest.fail "expected nested runtime failure"
    | Exit.Error cause -> check_die_message "nested runtime" "Runtime.run" cause

  let test_blocking_user_exit_not_swallowed_as_interrupt () =
    B.with_runtime @@ fun _ctx rt ->
    let pool = BP.create ~name:"user-exit" (blocking_config ~max_threads:1 ()) in
    let result =
      B.run rt
        (Eta_blocking.run ~pool ~name:"user-exit.raise" (fun () ->
             raise Stdlib.Exit))
    in
    match result with
    | Exit.Ok _ -> Alcotest.fail "expected error from raise Exit"
    | Exit.Error cause ->
        let is_die = match cause with Cause.Die _ -> true | _ -> false in
        let is_interrupt = Cause.is_interrupt_only cause in
        Alcotest.(check bool)
          "user Exit should NOT be mapped to interrupt" false is_interrupt;
        Alcotest.(check bool)
          "user Exit should be Die (unexpected exception)" true is_die

  let tests =
    [
      ( "Blocking",
        [
          Alcotest.test_case "run and stats" `Quick
            test_blocking_run_and_stats;
          Alcotest.test_case "stats separate waiting from queue" `Quick
            test_blocking_stats_separate_waiting_from_queue;
          Alcotest.test_case "cancelled admission waiter records evidence" `Quick
            test_blocking_cancelled_admission_waiter_records_evidence;
          Alcotest.test_case "run executes blocking function" `Quick
            test_blocking_run_executes;
          Alcotest.test_case "try_run completes" `Quick
            test_blocking_try_run_completes;
          Alcotest.test_case "try_run reports saturation" `Quick
            test_blocking_try_run_reports_saturation_without_queueing;
          Alcotest.test_case "result lifts result" `Quick
            test_blocking_result_lifts_result_value;
          Alcotest.test_case "try_run_result completes Ok" `Quick
            test_blocking_try_run_result_completes_ok;
          Alcotest.test_case "try_run_result preserves Error" `Quick
            test_blocking_try_run_result_preserves_error;
          Alcotest.test_case "try_run exception is defect" `Quick
            test_blocking_try_run_exception_is_defect;
          Alcotest.test_case "result short aliases" `Quick
            test_blocking_result_short_aliases;
          Alcotest.test_case "result exception is defect" `Quick
            test_blocking_result_exception_is_defect;
          Alcotest.test_case "result_timeout interrupts" `Quick
            test_blocking_result_timeout_interrupts_and_fails_typed;
          Alcotest.test_case "result_timeout cancels once" `Quick
            test_blocking_result_timeout_calls_on_cancel_once;
          Alcotest.test_case "result_timeout bounds caller wait" `Quick
            test_blocking_result_timeout_bounds_started_drain_wait;
          Alcotest.test_case "result_timeout cancels queued work" `Quick
            test_blocking_result_timeout_cancels_queued_work;
          Alcotest.test_case "started cancellation nonpreemptive" `Quick
            test_blocking_started_cancellation_is_nonpreemptive;
          Alcotest.test_case "shutdown interrupts new jobs" `Quick
            test_blocking_shutdown_interrupts_new_jobs;
          Alcotest.test_case "try_run reports shutdown" `Quick
            test_blocking_try_run_reports_shutdown;
          Alcotest.test_case "shutdown drain waits" `Quick
            test_blocking_shutdown_drain_waits_for_started;
          Alcotest.test_case "shutdown drain runs queued" `Quick
            test_blocking_shutdown_drain_runs_queued_job;
          Alcotest.test_case "shutdown detach interrupts queued" `Quick
            test_blocking_shutdown_detach_interrupts_queued_job;
          Alcotest.test_case "shutdown drain interrupts admission waiter" `Quick
            test_blocking_shutdown_drain_interrupts_admission_waiter;
          Alcotest.test_case "shutdown detach interrupts admission waiter"
            `Quick test_blocking_shutdown_detach_interrupts_admission_waiter;
          Alcotest.test_case "worker rejects nested run" `Quick
            test_blocking_worker_rejects_nested_run;
          Alcotest.test_case "worker rejects runtime run" `Quick
            test_blocking_worker_rejects_runtime_run;
          Alcotest.test_case "user Exit not swallowed as interrupt" `Quick
            test_blocking_user_exit_not_swallowed_as_interrupt;
        ] );
    ]
end
