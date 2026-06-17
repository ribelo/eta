module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  open Eta

  module BP = Eta_blocking.Pool
  module E = Effect

  let blocking_config ?(max_threads = 4) ?(max_queued = 64)
      ?(queue_policy = BP.Wait) ?(shutdown_policy = BP.Drain) () : BP.config =
    { max_threads; max_queued; queue_policy; shutdown_policy }

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
        (blocking_config ~max_threads:1 ~max_queued:0 ~queue_policy:BP.Reject
           ~shutdown_policy:BP.Drain ())
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
        (blocking_config ~max_threads:1 ~max_queued:1 ~queue_policy:BP.Wait
           ~shutdown_policy:BP.Drain ())
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

  let test_blocking_reject_policy_deterministic () =
    B.with_runtime @@ fun ctx rt ->
    let pool =
      BP.create ~name:"reject"
        (blocking_config ~max_threads:1 ~max_queued:0 ~queue_policy:BP.Reject ())
    in
    let first =
      B.fork_run ctx rt
        (Eta_blocking.run ~pool ~name:"reject.first" (fun () ->
             Unix.sleepf 0.060))
    in
    wait_until (fun () -> (BP.stats pool).active = 1);
    let rejected =
      List.init 4 (fun _ ->
          match
            B.run rt
              (Eta_blocking.run ~pool ~name:"reject.extra" (fun () -> ()))
          with
          | Exit.Ok _ -> false
          | Exit.Error _ -> true)
    in
    Alcotest.(check int) "rejected count observed" 4
      (List.length (List.filter Fun.id rejected));
    Alcotest.(check int) "rejected stats" 4 (BP.stats pool).rejected;
    check_exit_ok Alcotest.unit "first" () (B.await first)

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

  let test_blocking_shutdown_rejects_new_jobs () =
    B.with_runtime @@ fun _ctx rt ->
    let pool = BP.create ~name:"shutdown" (blocking_config ()) in
    run_ok rt (BP.shutdown pool);
    match
      B.run rt
        (Eta_blocking.run ~pool ~name:"after-shutdown" (fun () -> ()))
    with
    | Exit.Ok _ -> Alcotest.fail "expected shutdown rejection"
    | Exit.Error cause -> check_die_message "shutdown" "Pool_shutting_down" cause

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
          Alcotest.test_case "result lifts result" `Quick
            test_blocking_result_lifts_result_value;
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
          Alcotest.test_case "reject deterministic" `Quick
            test_blocking_reject_policy_deterministic;
          Alcotest.test_case "started cancellation nonpreemptive" `Quick
            test_blocking_started_cancellation_is_nonpreemptive;
          Alcotest.test_case "shutdown rejects new jobs" `Quick
            test_blocking_shutdown_rejects_new_jobs;
          Alcotest.test_case "shutdown drain waits" `Quick
            test_blocking_shutdown_drain_waits_for_started;
          Alcotest.test_case "worker rejects nested run" `Quick
            test_blocking_worker_rejects_nested_run;
          Alcotest.test_case "worker rejects runtime run" `Quick
            test_blocking_worker_rejects_runtime_run;
          Alcotest.test_case "user Exit not swallowed as interrupt" `Quick
            test_blocking_user_exit_not_swallowed_as_interrupt;
        ] );
    ]
end
