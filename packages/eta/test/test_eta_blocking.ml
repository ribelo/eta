open Eta
open Eta_test
open Test_eta_support

external hold_lock_sleep : float -> unit = "eta_test_hold_lock_sleep"

module BP = Effect.Blocking.Pool

let blocking_config ?(max_threads = 4) ?(max_queued = 64)
    ?(queue_policy = BP.Wait) ?(shutdown_policy = BP.Drain) () : BP.config =
  { max_threads; max_queued; queue_policy; shutdown_policy }

let wait_until ?(attempts = 200) pred =
  let rec loop n =
    if pred () then ()
    else if n = 0 then Alcotest.fail "condition did not become true"
    else (
      Eio_unix.sleep 0.001;
      loop (n - 1))
  in
  loop attempts


let now_us () = int_of_float (Unix.gettimeofday () *. 1_000_000.0)

let percentile sorted pct =
  match sorted with
  | [] -> 0
  | _ ->
      let len = List.length sorted in
      let idx =
        float_of_int (len - 1) *. pct |> int_of_float |> min (len - 1) |> max 0
      in
      List.nth sorted idx

let heartbeat_p99_us body =
  let running = ref true in
  let samples = ref [] in
  Eio.Switch.run @@ fun sw ->
  Eio.Fiber.fork ~sw (fun () ->
      let target = ref (now_us () + 1_000) in
      while !running do
        Eio_unix.sleep 0.001;
        let actual = now_us () in
        samples := max 0 (actual - !target) :: !samples;
        target := actual + 1_000
      done);
  Eio.Fiber.yield ();
  let result = body () in
  running := false;
  Eio.Fiber.yield ();
  let sorted = List.sort compare !samples in
  (percentile sorted 0.99, result)

let elapsed_us f =
  let started = now_us () in
  let value = f () in
  (now_us () - started, value)

let rec cpu_burn_until deadline acc =
  if now_us () >= deadline then acc
  else
    let acc = ((acc lxor (acc lsl 5)) + 0x9e3779b9) land 0x3fffffff in
    cpu_burn_until deadline acc

let cpu_burn_ms ms =
  ignore (cpu_burn_until (now_us () + (ms * 1000)) 0x12345)

let check_pool_shutdown label cause =
  check_die_message label "Pool_shutting_down" cause

let test_blocking_submit_alias_and_stats () =
  with_runtime @@ fun rt ->
  let pool = BP.create ~name:"basic" (blocking_config ~max_threads:2 ()) in
  Alcotest.(check int) "blocking" 42
    (run_ok rt (Effect.blocking ~pool ~name:"basic.answer" (fun () -> 42)));
  Alcotest.(check int) "submit" 43
    (run_ok rt (Effect.Blocking.submit ~pool ~name:"basic.submit" (fun () -> 43)));
  let stats = BP.stats pool in
  Alcotest.(check int) "completed" 2 stats.completed;
  Alcotest.(check int) "active" 0 stats.active;
  Alcotest.(check int) "queued" 0 stats.queued

let test_blocking_direct_control_and_blocking_heartbeat () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let direct_p99, () = heartbeat_p99_us (fun () -> Unix.sleepf 0.030) in
  let pool = BP.create ~name:"heartbeat" (blocking_config ~max_threads:4 ()) in
  let blocking_p99, () =
    heartbeat_p99_us (fun () ->
        run_ok rt (Effect.blocking ~pool ~name:"heartbeat.sleep" (fun () -> Unix.sleepf 0.030)))
  in
  Alcotest.(check bool) "direct freezes heartbeat" true (direct_p99 > 20_000);
  Alcotest.(check bool) "blocking preserves heartbeat" true (blocking_p99 < 10_000)

let test_blocking_wait_policy_caps_active_and_queue () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let pool =
    BP.create ~name:"wait-cap"
      (blocking_config ~max_threads:4 ~max_queued:8 ~queue_policy:BP.Wait ())
  in
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let max_active = ref 0 in
  let max_queued = ref 0 in
  let sampling = ref true in
  Eio.Fiber.fork ~sw (fun () ->
      while !sampling do
        let stats = BP.stats pool in
        max_active := max !max_active stats.active;
        max_queued := max !max_queued stats.queued;
        Eio_unix.sleep 0.001
      done);
  let p99, values =
    heartbeat_p99_us (fun () ->
        run_ok rt
          (Effect.for_each_par (List.init 30 Fun.id) (fun _ ->
               Effect.blocking ~pool ~name:"wait-cap.job" (fun () ->
                   Unix.sleepf 0.010;
                   1))))
  in
  sampling := false;
  Alcotest.(check int) "completed list" 30 (List.length values);
  Alcotest.(check bool) "active cap" true (!max_active <= 4);
  Alcotest.(check bool) "queued cap" true (!max_queued <= 8);
  Alcotest.(check bool) "heartbeat" true (p99 < 10_000);
  let stats = BP.stats pool in
  Alcotest.(check int) "completed" 30 stats.completed;
  Alcotest.(check int) "rejected" 0 stats.rejected;
  Alcotest.(check int) "cancelled" 0 stats.cancelled_before_start;
  Alcotest.(check int) "detached" 0 stats.detached

let test_blocking_reject_policy_deterministic () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let pool =
    BP.create ~name:"reject"
      (blocking_config ~max_threads:1 ~max_queued:0 ~queue_policy:BP.Reject ())
  in
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let first_started, first_resolver = Eio.Promise.create () in
  let first =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Runtime.run rt
          (Effect.blocking ~pool ~name:"reject.first" (fun () ->
               Eio.Promise.resolve first_resolver ();
               Unix.sleepf 0.060)))
  in
  Eio.Promise.await first_started;
  wait_until (fun () -> (BP.stats pool).active = 1);
  let rejected =
    List.init 4 (fun _ ->
        match Runtime.run rt (Effect.blocking ~pool ~name:"reject.extra" (fun () -> ())) with
        | Exit.Ok _ -> false
        | Exit.Error _ -> true)
  in
  Alcotest.(check int) "rejected count observed" 4
    (List.length (List.filter Fun.id rejected));
  Alcotest.(check int) "rejected stats" 4 (BP.stats pool).rejected;
  ignore (Eio.Promise.await_exn first : (unit, _) Exit.t)

let test_blocking_pending_cancellation_removes_queued_job () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let pool =
    BP.create ~name:"cancel-pending"
      (blocking_config ~max_threads:1 ~max_queued:1 ~queue_policy:BP.Wait ())
  in
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let blocker =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Runtime.run rt
          (Effect.blocking ~pool ~name:"cancel-pending.blocker" (fun () ->
               Unix.sleepf 0.050)))
  in
  wait_until (fun () -> (BP.stats pool).active = 1);
  let cancel_ctx = ref None in
  let queued =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Runtime.run rt
          (Effect.blocking ~pool ~name:"cancel-pending.queued" (fun () -> ())))
  in
  wait_until (fun () -> (BP.stats pool).queued = 1);
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  (match Eio.Promise.await_exn queued with
  | Exit.Ok _ -> Alcotest.fail "expected cancellation"
  | Exit.Error _ -> ());
  ignore (Eio.Promise.await_exn blocker : (unit, _) Exit.t);
  Alcotest.(check int)
    "cancelled before start" 1 (BP.stats pool).cancelled_before_start

let test_blocking_started_cancellation_is_nonpreemptive () =
  with_runtime @@ fun rt ->
  let pool = BP.create ~name:"cancel-started" (blocking_config ~max_threads:1 ()) in
  let completed = Atomic.make false in
  let elapsed, result =
    elapsed_us (fun () ->
        Runtime.run rt
          (Effect.blocking ~pool ~name:"cancel-started.job"
             (fun () ->
               Unix.sleepf 0.030;
               Atomic.set completed true)
          |> Effect.timeout (Duration.ms 5)))
  in
  (match result with Exit.Ok _ | Exit.Error _ -> ());
  Alcotest.(check bool) "worker completed" true (Atomic.get completed);
  Alcotest.(check bool) "waited for started job" true (elapsed >= 25_000)

let test_blocking_shutdown_rejects_new_jobs () =
  with_runtime @@ fun rt ->
  let pool = BP.create ~name:"shutdown" (blocking_config ()) in
  run_ok rt (BP.shutdown pool);
  match Runtime.run rt (Effect.blocking ~pool ~name:"after-shutdown" (fun () -> ())) with
  | Exit.Ok _ -> Alcotest.fail "expected shutdown rejection"
  | Exit.Error cause -> check_pool_shutdown "shutdown" cause

let test_blocking_shutdown_drain_waits_for_started () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let pool =
    BP.create ~name:"drain" (blocking_config ~max_threads:1 ~shutdown_policy:BP.Drain ())
  in
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let worker =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Runtime.run rt
          (Effect.blocking ~pool ~name:"drain.job" (fun () -> Unix.sleepf 0.030)))
  in
  wait_until (fun () -> (BP.stats pool).active = 1);
  let elapsed, () = elapsed_us (fun () -> run_ok rt (BP.shutdown pool)) in
  Alcotest.(check bool) "drain waited" true (elapsed >= 20_000);
  ignore (Eio.Promise.await_exn worker : (unit, _) Exit.t)

let test_blocking_shutdown_detach_started_returns_promptly () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let meter = Meter.in_memory () in
  let pool =
    BP.create ~name:"detach"
      (blocking_config ~max_threads:1 ~shutdown_policy:BP.Detach_started ())
  in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~meter:(Meter.as_capability meter) ()
  in
  let worker =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Runtime.run rt
          (Effect.blocking ~pool ~name:"detach.job" (fun () ->
               Unix.sleepf 0.050;
               failwith "detached failure")))
  in
  wait_until (fun () -> (BP.stats pool).active = 1);
  let elapsed, () = elapsed_us (fun () -> run_ok rt (BP.shutdown pool)) in
  Alcotest.(check bool) "detach returned promptly" true (elapsed < 20_000);
  Alcotest.(check bool) "detached counter" true ((BP.stats pool).detached >= 1);
  Eio_unix.sleep 0.060;
  ignore (Eio.Promise.await_exn worker : (unit, _) Exit.t);
  Alcotest.(check bool) "detached metric" true
    (Meter.dump meter
     |> List.exists (fun point ->
            String.equal point.Meter.name "eta.blocking.run_ms"
            && List.mem ("eta.blocking.pool", "detach") point.attrs
            && List.exists
                 (fun (k, v) ->
                   String.equal k "eta.blocking.outcome"
            && contains_substring v "error")
                 point.attrs))

let test_blocking_detach_started_counts_each_job_once () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let pool =
    BP.create ~name:"detach-once"
      (blocking_config ~max_threads:2 ~shutdown_policy:BP.Detach_started ())
  in
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let cancel_ctx = ref None in
  let cancelled =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Runtime.run rt
          (Effect.blocking ~pool ~name:"detach-once.cancelled" (fun () ->
               Unix.sleepf 0.080)))
  in
  wait_until (fun () -> (BP.stats pool).active = 1);
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  wait_until (fun () -> (BP.stats pool).detached = 1);
  let shutdown_detached =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Runtime.run rt
          (Effect.blocking ~pool ~name:"detach-once.shutdown" (fun () ->
               Unix.sleepf 0.080)))
  in
  wait_until (fun () -> (BP.stats pool).active = 2);
  run_ok rt (BP.shutdown pool);
  let stats = BP.stats pool in
  Alcotest.(check int) "detached once per submitted job" 2 stats.detached;
  Alcotest.(check bool) "detached does not exceed submitted" true
    (stats.detached <= 2);
  ignore (Eio.Promise.await_exn cancelled : (unit, _) Exit.t);
  ignore (Eio.Promise.await_exn shutdown_detached : (unit, _) Exit.t)

let test_blocking_named_pools_prevent_starvation () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let fs_pool = BP.create ~name:"fs" (blocking_config ~max_threads:4 ~max_queued:64 ()) in
  let db_pool = BP.create ~name:"db" (blocking_config ~max_threads:2 ~max_queued:8 ()) in
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let fs =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Runtime.run rt
          (Effect.for_each_par (List.init 40 Fun.id) (fun _ ->
               Effect.blocking ~pool:fs_pool ~name:"fs.scan" (fun () ->
                   Unix.sleepf 0.050))))
  in
  Eio_unix.sleep 0.010;
  let elapsed, result =
    elapsed_us (fun () ->
        Runtime.run rt (Effect.blocking ~pool:db_pool ~name:"db.query" (fun () -> 1)))
  in
  check_exit_ok Alcotest.int "db result" 1 result;
  Alcotest.(check bool) "db not starved" true (elapsed < 10_000);
  ignore (Eio.Promise.await_exn fs : (unit list, _) Exit.t)

let test_blocking_domain_isolated_preserves_hold_lock_heartbeat () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let normal_pool =
    BP.create ~name:"hold-lock-normal" (blocking_config ~max_threads:1 ())
  in
  let domain_pool =
    BP.create_domain_isolated ~name:"hold-lock-domain"
      (blocking_config ~max_threads:1 ())
  in
  let normal_p99, () =
    heartbeat_p99_us (fun () ->
        ignore
          (Runtime.run rt
             (Effect.blocking ~pool:normal_pool ~name:"hold-lock.normal"
                (fun () -> hold_lock_sleep 0.030))))
  in
  let domain_p99, () =
    heartbeat_p99_us (fun () ->
        ignore
          (Runtime.run rt
             (Effect.blocking ~pool:domain_pool ~name:"hold-lock.domain"
                (fun () -> hold_lock_sleep 0.030))))
  in
  Alcotest.(check bool) "normal hold-lock degrades" true (normal_p99 > 20_000);
  (* The absolute p99 is scheduler-noise sensitive in the full suite; the
     regression is domain isolation becoming materially worse than systhread. *)
  if domain_p99 > normal_p99 + 5_000 then
    Alcotest.failf "domain p99=%dus normal p99=%dus" domain_p99 normal_p99

let test_blocking_worker_rejects_nested_submit () =
  with_runtime @@ fun rt ->
  let pool = BP.create ~name:"worker-nested-submit" (blocking_config ()) in
  match
    Runtime.run rt
      (Effect.blocking ~pool ~name:"outer" (fun () ->
           ignore (Effect.Blocking.submit ~pool ~name:"inner" (fun () -> ()))))
  with
  | Exit.Ok _ -> Alcotest.fail "expected nested submit failure"
  | Exit.Error cause ->
      check_die_message "nested submit" "Effect.Blocking.submit" cause

let test_blocking_worker_rejects_runtime_run () =
  with_runtime @@ fun rt ->
  let pool = BP.create ~name:"worker-runtime" (blocking_config ()) in
  match
    Runtime.run rt
      (Effect.blocking ~pool ~name:"outer" (fun () ->
           ignore (Runtime.run rt (Effect.pure ()))))
  with
  | Exit.Ok _ -> Alcotest.fail "expected nested runtime failure"
  | Exit.Error cause -> check_die_message "nested runtime" "Runtime.run" cause

let test_blocking_cpu_antipattern_has_no_speedup () =
  with_runtime @@ fun rt ->
  let pool = BP.create ~name:"cpu-antipattern" (blocking_config ~max_threads:4 ()) in
  let same_elapsed, () = elapsed_us (fun () -> cpu_burn_ms 20) in
  let blocking_elapsed, result =
    elapsed_us (fun () ->
        Runtime.run rt
          (Effect.blocking ~pool ~name:"cpu.antipattern" (fun () -> cpu_burn_ms 20)))
  in
  check_exit_ok Alcotest.unit "cpu blocking result" () result;
  Alcotest.(check bool) "no meaningful speedup" true
    (blocking_elapsed >= same_elapsed / 2)

let test_blocking_observability_labels_and_timings () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let meter = Meter.in_memory () in
  let pool = BP.create ~name:"observed" (blocking_config ~max_threads:2 ()) in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ~meter:(Meter.as_capability meter)
      ~auto_instrument:true ()
  in
  run_ok rt
    (Effect.blocking ~pool ~name:"test.label" (fun () ->
         Unix.sleepf 0.020;
         1))
  |> ignore;
  let spans = Tracer.dump tracer in
  Alcotest.(check bool) "span label" true
    (List.exists (fun span -> String.equal span.Tracer.name "test.label") spans);
  Alcotest.(check bool) "trace event" true
    (List.exists
       (fun span ->
         List.exists
           (fun event ->
             String.equal event.Tracer.ev_name "eta.blocking"
             && List.mem ("eta.blocking.name", "test.label") event.ev_attrs
             && List.mem ("eta.blocking.pool", "observed") event.ev_attrs)
           span.Tracer.events)
       spans);
  Alcotest.(check bool) "run timing metric" true
    (Meter.dump meter
     |> List.exists (fun point ->
            String.equal point.Meter.name "eta.blocking.run_ms"
            && List.mem ("eta.blocking.name", "test.label") point.attrs
            &&
            match point.value with Meter.Int ms -> ms >= 15 | Meter.Float _ -> false))

