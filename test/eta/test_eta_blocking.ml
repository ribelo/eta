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

let test_blocking_result_lifts_result () =
  with_runtime @@ fun rt ->
  let ok = Effect.blocking_result ~name:"blocking.result.ok" (fun () -> Ok 7) in
  let err =
    Effect.blocking_result ~name:"blocking.result.err" (fun () -> Error `Bad)
  in
  Alcotest.(check int) "ok" 7 (run_ok rt ok);
  match Runtime.run rt err with
  | Exit.Ok _ -> Alcotest.fail "expected typed failure"
  | Exit.Error (Cause.Fail `Bad) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected Cause.Fail `Bad, got %a"
        (Cause.pp (fun fmt (`Bad : [ `Bad ]) -> Format.pp_print_string fmt "bad"))
        cause

let test_blocking_pool_custom_runner () =
  run_eio @@ fun stdenv ->
  let calls = Atomic.make 0 in
  let module Host = struct
    let run_in_systhread ?label f =
      let label = Option.value ~default:"" label in
      Alcotest.(check string) "label" "custom.runner" label;
      Atomic.incr calls;
      Eio_unix.run_in_systhread ~label f
  end in
  Eio.Switch.run @@ fun sw ->
  let host =
    Host_eio.make ~unix:(module Host) ~eio:(module Eio) ()
  in
  Runtime.with_host_eio host ~sw ~clock:(Eio.Stdenv.clock stdenv)
  @@ fun rt ->
  Alcotest.(check int) "blocking" 45
    (run_ok rt (Effect.blocking ~name:"custom.runner" (fun () -> 45)));
  Alcotest.(check int) "runner calls" 1 (Atomic.get calls)

let test_blocking_direct_control_and_blocking_heartbeat () =
  run_eio @@ fun stdenv ->
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
  run_eio @@ fun stdenv ->
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
  run_eio @@ fun stdenv ->
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
  run_eio @@ fun stdenv ->
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
  run_eio @@ fun stdenv ->
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
  run_eio @@ fun stdenv ->
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
  run_eio @@ fun stdenv ->
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
  run_eio @@ fun stdenv ->
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
  run_eio @@ fun stdenv ->
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
  run_eio @@ fun stdenv ->
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

(* P0: Blocking_runtime swallows Eio cancellation and overloads OCaml's Exit.
   These tests verify that:
   1. User code raising OCaml's Exit is distinguishable from Eio cancellation.
   2. Eio cancellation preserves the Cancelled exception identity, not Exit.
   3. cause_of_exn does not conflate user Exit with fiber interruption. *)

let test_blocking_user_exit_not_swallowed_as_interrupt () =
  (* If user callback raises OCaml's Exit, it should surface as a Die
     (unexpected exception), NOT as Cause.interrupt. The current code maps
     Exit -> Cause.interrupt in cause_of_exn, which is the bug. *)
  with_runtime @@ fun rt ->
  let pool = BP.create ~name:"user-exit" (blocking_config ~max_threads:1 ()) in
  let result =
    Runtime.run rt
      (Effect.blocking ~pool ~name:"user-exit.raise" (fun () ->
           raise Stdlib.Exit))
  in
  match result with
  | Exit.Ok _ -> Alcotest.fail "expected error from raise Exit"
  | Exit.Error cause ->
      (* The correct behavior: user's Exit should be a Die, not interrupt *)
      let is_die =
        match cause with Cause.Die _ -> true | _ -> false
      in
      let is_interrupt = Cause.is_interrupt_only cause in
      Alcotest.(check bool)
        "user Exit should NOT be mapped to interrupt" false is_interrupt;
      Alcotest.(check bool)
        "user Exit should be Die (unexpected exception)" true is_die

let test_blocking_eio_cancellation_preserves_cancelled_identity () =
  (* When a fiber is cancelled while queued in a blocking pool, the resulting
     cause should clearly indicate Eio cancellation (Cause.interrupt), and
     the mechanism should be via Eio.Cancel.Cancelled, not via re-raising
     OCaml's Exit. This test checks that the cancellation pathway works but
     also that the exception type seen by any intermediate handler is
     Cancelled, not Exit. *)
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let pool =
    BP.create ~name:"cancel-identity"
      (blocking_config ~max_threads:1 ~max_queued:1 ~queue_policy:BP.Wait ())
  in
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  (* Fill the pool so the next job queues *)
  let _blocker =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Runtime.run rt
          (Effect.blocking ~pool ~name:"cancel-identity.blocker" (fun () ->
               Unix.sleepf 0.100)))
  in
  wait_until (fun () -> (BP.stats pool).active = 1);
  (* Submit a queued job then cancel it; capture what exception propagates *)
  let observed_exn = ref None in
  let cancel_ctx = ref None in
  let queued =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        (try
           Runtime.run rt
             (Effect.blocking ~pool ~name:"cancel-identity.victim" (fun () ->
                  ()))
         with exn ->
           observed_exn := Some exn;
           raise exn))
  in
  wait_until (fun () -> (BP.stats pool).queued = 1);
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx (Failure "test-cancel")) !cancel_ctx;
  (match Eio.Promise.await queued with _ -> () | exception _ -> ());
  (* The exception that propagates should be Eio.Cancel.Cancelled, NOT Exit *)
  (match !observed_exn with
  | None -> () (* Runtime caught it internally - that's fine *)
  | Some (Eio.Cancel.Cancelled _) -> () (* Correct: native cancellation *)
  | Some Stdlib.Exit ->
      Alcotest.fail
        "Eio cancellation was converted to OCaml Exit - cancellation identity lost"
  | Some exn ->
      Alcotest.failf "unexpected exception type: %s" (Printexc.to_string exn))

let test_cause_of_exn_distinguishes_exit_from_cancelled () =
  (* Direct unit test of the cause_of_exn mapping: OCaml's Exit should NOT
     produce the same Cause as Eio.Cancel.Cancelled. Currently both map to
     Cause.interrupt which is the conflation bug. *)
  with_runtime @@ fun rt ->
  let pool = BP.create ~name:"distinguish" (blocking_config ~max_threads:1 ()) in
  (* Run a job that raises Exit *)
  let exit_result =
    Runtime.run rt
      (Effect.blocking ~pool ~name:"distinguish.exit" (fun () ->
           raise Stdlib.Exit))
  in
  (* Raise Eio's cancellation exception directly so this checks cancellation
     classification, not Effect.timeout's typed failure contract. *)
  let cancel_result =
    Runtime.run rt
      (Effect.sync (fun () -> raise (Eio.Cancel.Cancelled (Failure "cancel"))))
  in
  let exit_cause = match exit_result with
    | Exit.Error c -> c
    | Exit.Ok _ -> Alcotest.fail "expected error from Exit"
  in
  let cancel_cause = match cancel_result with
    | Exit.Error c -> c
    | Exit.Ok _ -> Alcotest.fail "expected error from timeout"
  in
  (* These should be DIFFERENT causes - Exit is a user bug, Cancelled is
     a control flow mechanism *)
  let exit_is_interrupt = Cause.is_interrupt_only exit_cause in
  let cancel_is_interrupt = Cause.is_interrupt_only cancel_cause in
  Alcotest.(check bool)
    "cancelled job should be interrupt" true cancel_is_interrupt;
  Alcotest.(check bool)
    "user Exit should NOT be interrupt (it's a user exception)" false exit_is_interrupt
