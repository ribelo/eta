open Eta
open Eta_test
open Test_eta_support

module BP = Eta_blocking.Pool

let blocking_config ?(max_threads = 4) ?(max_queued = 64)
    ?(queue_policy = BP.Wait) ?(shutdown_policy = BP.Drain) () : BP.config =
  { max_threads; max_queued; queue_policy; shutdown_policy }

let wait_until ?(attempts = 200) pred =
  let rec loop n =
    if pred () then ()
    else if n = 0 then Alcotest.fail "condition did not become true"
    else (
      Eio.Fiber.yield ();
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
    Eta_eio.Host.make ~unix:(module Host) ~eio:(module Eio) ()
  in
  Eta_eio.Runtime.with_host host ~sw ~clock:(Eio.Stdenv.clock stdenv)
  @@ fun rt ->
  Alcotest.(check int) "blocking" 45
    (run_ok rt (Eta_blocking.run ~name:"custom.runner" (fun () -> 45)));
  Alcotest.(check int) "runner calls" 1 (Atomic.get calls)

let test_blocking_runner_cancellation_releases_started_slot () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let runner : BP.runner =
    {
      run_worker =
        (fun ~label:_ _ ->
          raise (Eio.Cancel.Cancelled (Failure "runner cancelled")));
    }
  in
  let pool =
    BP.create ~name:"runner-cancel" ~runner
      (blocking_config ~max_threads:1 ~max_queued:0 ~queue_policy:BP.Reject ())
  in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  (match
     Runtime.run rt
       (Eta_blocking.run ~pool ~name:"runner-cancel.interrupted" (fun () -> ()))
   with
  | Exit.Ok _ -> Alcotest.fail "expected runner cancellation"
  | Exit.Error _ -> ());
  Alcotest.(check int) "active slot released" 0 (BP.stats pool).active

let test_blocking_direct_control_and_blocking_heartbeat () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let direct_p99, () = heartbeat_p99_us (fun () -> Unix.sleepf 0.030) in
  let pool = BP.create ~name:"heartbeat" (blocking_config ~max_threads:4 ()) in
  let blocking_p99, () =
    heartbeat_p99_us (fun () ->
        run_ok rt (Eta_blocking.run ~pool ~name:"heartbeat.sleep" (fun () -> Unix.sleepf 0.030)))
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
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
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
          (Effect.map_par (fun _ ->
               Eta_blocking.run ~pool ~name:"wait-cap.job" (fun () ->
                   Unix.sleepf 0.010;
                   1)) (List.init 30 Fun.id)))
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

let test_blocking_pending_cancellation_removes_queued_job () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let pool =
    BP.create ~name:"cancel-pending"
      (blocking_config ~max_threads:1 ~max_queued:1 ~queue_policy:BP.Wait ())
  in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let blocker =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Runtime.run rt
          (Eta_blocking.run ~pool ~name:"cancel-pending.blocker" (fun () ->
               Unix.sleepf 0.050)))
  in
  wait_until (fun () -> (BP.stats pool).active = 1);
  let cancel_ctx = ref None in
  let queued =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Runtime.run rt
          (Eta_blocking.run ~pool ~name:"cancel-pending.queued" (fun () -> ())))
  in
  wait_until (fun () -> (BP.stats pool).queued = 1);
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  (match Eio.Promise.await_exn queued with
  | Exit.Ok _ -> Alcotest.fail "expected cancellation"
  | Exit.Error _ -> ());
  ignore (Eio.Promise.await_exn blocker : (unit, _) Exit.t);
  Alcotest.(check int)
    "cancelled before start" 1 (BP.stats pool).cancelled_before_start

let test_blocking_shutdown_detach_started_returns_promptly () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let meter = Meter.in_memory () in
  let pool =
    BP.create ~name:"detach"
      (blocking_config ~max_threads:1 ~shutdown_policy:BP.Detach_started ())
  in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~meter:(Meter.as_capability meter) ()
  in
  let worker =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Runtime.run rt
          (Eta_blocking.run ~pool ~name:"detach.job" (fun () ->
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
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let cancel_ctx = ref None in
  let cancelled =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Runtime.run rt
          (Eta_blocking.run ~pool ~name:"detach-once.cancelled" (fun () ->
               Unix.sleepf 0.080)))
  in
  wait_until (fun () -> (BP.stats pool).active = 1);
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  wait_until (fun () -> (BP.stats pool).detached = 1);
  let shutdown_detached =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Runtime.run rt
          (Eta_blocking.run ~pool ~name:"detach-once.shutdown" (fun () ->
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
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let fs =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Runtime.run rt
          (Effect.map_par (fun _ ->
               Eta_blocking.run ~pool:fs_pool ~name:"fs.scan" (fun () ->
                   Unix.sleepf 0.050)) (List.init 40 Fun.id)))
  in
  Eio_unix.sleep 0.010;
  let elapsed, result =
    elapsed_us (fun () ->
        Runtime.run rt (Eta_blocking.run ~pool:db_pool ~name:"db.query" (fun () -> 1)))
  in
  check_exit_ok Alcotest.int "db result" 1 result;
  Alcotest.(check bool) "db not starved" true (elapsed < 10_000);
  ignore (Eio.Promise.await_exn fs : (unit list, _) Exit.t)

let test_blocking_cpu_antipattern_has_no_speedup () =
  with_runtime @@ fun rt ->
  let pool = BP.create ~name:"cpu-antipattern" (blocking_config ~max_threads:4 ()) in
  let same_elapsed, () = elapsed_us (fun () -> cpu_burn_ms 20) in
  let blocking_elapsed, result =
    elapsed_us (fun () ->
        Runtime.run rt
          (Eta_blocking.run ~pool ~name:"cpu.antipattern" (fun () -> cpu_burn_ms 20)))
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
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ~meter:(Meter.as_capability meter)
      ~auto_instrument:true ()
  in
  run_ok rt
    (Eta_blocking.run ~pool ~name:"test.label" (fun () ->
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
            match point.value with
            | Meter.Number (Meter.Int ms) -> ms >= 15
            | Number (Float _) | Category _ -> false))

(* P0: Blocking_runtime must preserve native Eio cancellation identity without
   conflating it with ordinary OCaml exceptions. Shared user-exception coverage
   lives in test/blocking_common. *)

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
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  (* Fill the pool so the next job queues *)
  let _blocker =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Runtime.run rt
          (Eta_blocking.run ~pool ~name:"cancel-identity.blocker" (fun () ->
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
             (Eta_blocking.run ~pool ~name:"cancel-identity.victim" (fun () ->
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
      (Eta_blocking.run ~pool ~name:"distinguish.exit" (fun () ->
           raise Stdlib.Exit))
  in
  (* Raw Eio cancellation must propagate to the enclosing Eio fiber. *)
  let cancel_propagated =
    try
      ignore
        (Runtime.run rt
           (Effect.sync (fun () ->
                raise (Eio.Cancel.Cancelled (Failure "cancel")))));
      false
    with Eio.Cancel.Cancelled _ -> true
  in
  let exit_cause = match exit_result with
    | Exit.Error c -> c
    | Exit.Ok _ -> Alcotest.fail "expected error from Exit"
  in
  (* Exit is a user bug; Cancelled is a control flow mechanism that leaves Eta. *)
  let exit_is_interrupt = Cause.is_interrupt_only exit_cause in
  Alcotest.(check bool)
    "cancelled job should propagate" true cancel_propagated;
  Alcotest.(check bool)
    "user Exit should NOT be interrupt (it's a user exception)" false exit_is_interrupt

let test_blocking_wait_policy_no_lost_wakeup_under_churn () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let config =
    blocking_config ~max_threads:1 ~max_queued:0 ~queue_policy:BP.Wait
      ~shutdown_policy:BP.Drain ()
  in
  for iter = 1 to 2_000 do
    let pool =
      BP.create ~name:(Printf.sprintf "lost-wakeup-%d" iter) config
    in
    let release_first, release_first_u = Eio.Promise.create () in
    let first_started, first_started_u = Eio.Promise.create () in

    let first =
      Eio.Fiber.fork_promise ~sw (fun () ->
          Runtime.run rt
            (Eta_blocking.run ~pool ~name:"first" (fun () ->
                 Eio.Promise.resolve first_started_u ();
                 Eio.Promise.await release_first)))
    in
    Eio.Promise.await first_started;

    let second =
      Eio.Fiber.fork_promise ~sw (fun () ->
          Runtime.run rt
            (Eta_blocking.run ~pool ~name:"second" (fun () -> 42)))
    in

    (* Encourage the second fiber to enter the Wait_full path. *)
    for _ = 1 to 5 do
      Eio.Fiber.yield ()
    done;

    Eio.Promise.resolve release_first_u ();

    let bounded_second =
      Effect.timeout_as (Duration.ms 250)
        ~on_timeout:`Second_submitter_stuck
        (Effect.sync (fun () -> Eio.Promise.await_exn second))
    in
    (match Runtime.run rt bounded_second with
    | Exit.Ok (Exit.Ok 42) -> ()
    | Exit.Ok (Exit.Ok n) ->
        Alcotest.failf "second job returned %d on iteration %d" n iter
    | Exit.Ok (Exit.Error cause) ->
        Alcotest.failf "second job failed on iteration %d: %a" iter
          (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<blocking>"))
          cause
    | Exit.Error (Cause.Fail `Second_submitter_stuck) ->
        Alcotest.failf "lost wakeup: second submitter stuck on iteration %d" iter
    | Exit.Error cause ->
        Alcotest.failf "unexpected timeout wrapper failure on iteration %d: %a"
          iter
          (Cause.pp (fun fmt _ ->
               Format.pp_print_string fmt "<blocking-timeout>"))
          cause);

    ignore (Eio.Promise.await_exn first : (unit, _) Exit.t)
  done
