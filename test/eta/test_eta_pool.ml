open Eta
open Eta_test
open Test_eta_support

type pool_test_error =
  [ `Pool_shutdown
  | `Pool_shutdown_timeout
  | `Timeout
  | `Open_failed
  | `Close_failed
  | `Health_failed
  ]

type pool_test_conn = {
  id : int;
  closed : bool ref;
  unhealthy : bool ref;
  uses : int ref;
}

type pool_test_factory = {
  next_id : int ref;
  opened : int ref;
  closed : int ref;
  live : int ref;
  max_live : int ref;
  unhealthy_ids : int list;
}

let make_pool_factory ?(unhealthy_ids = []) () =
  {
    next_id = ref 0;
    opened = ref 0;
    closed = ref 0;
    live = ref 0;
    max_live = ref 0;
    unhealthy_ids;
  }

let pool_open (factory : pool_test_factory) : (pool_test_conn, pool_test_error) Effect.t =
  Effect.sync @@ fun () ->
  incr factory.next_id;
  incr factory.opened;
  incr factory.live;
  factory.max_live := max !(factory.max_live) !(factory.live);
  {
    id = !(factory.next_id);
    closed = ref false;
    unhealthy = ref (List.mem !(factory.next_id) factory.unhealthy_ids);
    uses = ref 0;
  }

let pool_close (factory : pool_test_factory) (conn : pool_test_conn) :
    (unit, pool_test_error) Effect.t =
  Effect.sync @@ fun () ->
  if not !(conn.closed) then (
    conn.closed := true;
    incr factory.closed;
    decr factory.live)

let pool_health (conn : pool_test_conn) : (unit, pool_test_error) Effect.t =
  if !(conn.unhealthy) then Effect.fail `Health_failed else Effect.unit

let pool_use (conn : pool_test_conn) : (int, pool_test_error) Effect.t =
  Effect.sync @@ fun () ->
  if !(conn.closed) then Alcotest.fail "used closed connection";
  incr conn.uses;
  conn.id

let create_test_pool ?max_idle ?idle_lifetime ?max_lifetime ?health_check
    ?(idle_check_interval = Duration.ms 5) ~max_size factory =
  let health_check = Option.value health_check ~default:pool_health in
  Pool.create ~name:"test.pool" ~kind:"test" ~max_size ?max_idle
    ?idle_lifetime ?max_lifetime ~idle_check_interval
    ~acquire:(pool_open factory) ~release:(pool_close factory)
    ~health_check ()

let test_pool_reuses_idle_lifo () =
  with_runtime @@ fun rt ->
  let factory = make_pool_factory () in
  let pool = run_ok rt (create_test_pool ~max_size:2 factory) in
  let use_once = Pool.with_resource pool pool_use in
  let first = run_ok rt use_once in
  let second = run_ok rt use_once in
  Alcotest.(check int) "reused id" first second;
  let stats = Pool.stats pool in
  Alcotest.(check int) "one opened" 1 stats.Pool.opened;
  Alcotest.(check int) "idle" 1 stats.Pool.idle;
  Alcotest.(check int) "active" 0 stats.Pool.active;
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool);
  Alcotest.(check int) "closed on shutdown" 1 !(factory.closed)

let test_pool_with_resource_body_success_releases_resource () =
  with_runtime @@ fun rt ->
  let factory = make_pool_factory () in
  let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
  Alcotest.(check int) "result" 1
    (run_ok rt (Pool.with_resource pool pool_use));
  let stats = Pool.stats pool in
  Alcotest.(check int) "active" 0 stats.Pool.active;
  Alcotest.(check int) "idle" 1 stats.Pool.idle;
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool)

let test_pool_with_resource_body_typed_failure_releases_resource () =
  with_runtime @@ fun rt ->
  let factory = make_pool_factory () in
  let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
  (match Runtime.run rt (Pool.with_resource pool (fun _ -> Effect.fail `Open_failed)) with
  | Exit.Error (Cause.Fail `Open_failed) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected body typed failure, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<pool>")) cause
  | Exit.Ok _ -> Alcotest.fail "expected body typed failure");
  let stats = Pool.stats pool in
  Alcotest.(check int) "active" 0 stats.Pool.active;
  Alcotest.(check int) "idle" 1 stats.Pool.idle;
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool)

let test_pool_with_resource_body_defect_releases_resource () =
  with_runtime @@ fun rt ->
  let factory = make_pool_factory () in
  let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
  (match
     Runtime.run rt
       (Pool.with_resource pool (fun _ ->
            Effect.sync (fun () -> failwith "body defect")))
   with
  | Exit.Error (Cause.Die _) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected body defect, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<pool>")) cause
  | Exit.Ok _ -> Alcotest.fail "expected body defect");
  let stats = Pool.stats pool in
  Alcotest.(check int) "active" 0 stats.Pool.active;
  Alcotest.(check int) "idle" 1 stats.Pool.idle;
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool)

let test_pool_release_defect_releases_capacity () =
  with_runtime @@ fun rt ->
  let factory = make_pool_factory () in
  let release_attempts = ref 0 in
  let release conn =
    Effect.sync (fun () -> incr release_attempts)
    |> Effect.bind (fun () -> pool_close factory conn)
    |> Effect.bind (fun () ->
           if !release_attempts = 1 then
             Effect.sync (fun () -> failwith "release defect")
           else Effect.unit)
  in
  let pool =
    run_ok rt
      (Pool.create ~name:"test.pool" ~kind:"test" ~max_size:1 ~max_idle:0
         ~acquire:(pool_open factory) ~release ~health_check:pool_health ())
  in
  (match Runtime.run rt (Pool.with_resource pool (fun _ -> Effect.unit)) with
  | Exit.Error (Cause.Finalizer (Cause.Finalizer.Die _)) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected release defect, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<pool>"))
        cause
  | Exit.Ok () -> Alcotest.fail "expected release defect");
  let after_defect = Pool.stats pool in
  Alcotest.(check int) "active after release defect" 0 after_defect.Pool.active;
  Alcotest.(check int) "closed after release defect" 1 after_defect.Pool.closed;
  let replacement =
    Pool.with_resource pool pool_use
    |> Effect.timeout_as (Duration.ms 20) ~on_timeout:`Timeout
  in
  Alcotest.(check int) "capacity reusable after release defect" 2
    (run_ok rt replacement);
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool)

let test_pool_shutdown_reports_failure_after_closing_all_idle () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let factory = make_pool_factory () in
  let release_attempts = ref 0 in
  let release conn =
    Effect.sync (fun () -> incr release_attempts)
    |> Effect.bind (fun () ->
           if !release_attempts = 1 then Effect.fail `Close_failed
           else pool_close factory conn)
  in
  let pool =
    run_ok rt
      (Pool.create ~name:"test.pool" ~kind:"test" ~max_size:2 ~max_idle:2
         ~acquire:(pool_open factory) ~release ~health_check:pool_health ())
  in
  let hold =
    Pool.with_resource pool (fun _ -> Effect.delay (Duration.ms 5) Effect.unit)
  in
  let first = fork_run sw rt hold in
  let second = fork_run sw rt hold in
  check_exit_ok Alcotest.unit "first" () (Eio.Promise.await first);
  check_exit_ok Alcotest.unit "second" () (Eio.Promise.await second);
  wait_until (fun () -> (Pool.stats pool).Pool.idle = 2);
  (match Runtime.run rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) with
  | Exit.Error (Cause.Fail `Close_failed) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected close failure, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<pool>"))
        cause
  | Exit.Ok () -> Alcotest.fail "expected close failure");
  Alcotest.(check int) "all idle closes attempted" 2 !release_attempts;
  Alcotest.(check int) "pool accounting closed both" 2 (Pool.stats pool).Pool.closed

let test_pool_shutdown_release_defect_removes_idle_entry () =
  with_runtime @@ fun rt ->
  let pool =
    run_ok rt
      (Pool.create ~name:"defective-close" ~max_size:1 ~acquire:(Effect.pure ())
         ~release:(fun () -> Effect.sync (fun () -> failwith "close boom"))
         ())
  in
  run_ok rt (Pool.with_resource pool (fun () -> Effect.unit));
  (match Runtime.run rt (Pool.shutdown pool) with
  | Exit.Error (Cause.Die _) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected release defect, got %a"
        (Cause.pp (fun fmt -> function
          | `Pool_shutdown -> Format.pp_print_string fmt "Pool_shutdown"
          | `Pool_shutdown_timeout ->
              Format.pp_print_string fmt "Pool_shutdown_timeout"))
        cause
  | Exit.Ok () -> Alcotest.fail "expected release defect");
  let stats = Pool.stats pool in
  Alcotest.(check int) "idle removed after failed close" 0 stats.Pool.idle;
  Alcotest.(check int) "close was accounted" 1 stats.Pool.closed

let test_pool_max_size_respected_under_concurrent_checkout () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let factory = make_pool_factory () in
  let pool = run_ok rt (create_test_pool ~max_size:2 factory) in
  let use_for ms =
    Pool.with_resource pool (fun _ -> Effect.delay (Duration.ms ms) Effect.unit)
  in
  let first = fork_run sw rt (use_for 30) in
  let second = fork_run sw rt (use_for 30) in
  wait_until (fun () ->
      let stats = Pool.stats pool in
      stats.Pool.active = 2 && stats.Pool.opened = 2);
  let third = fork_run sw rt (use_for 1) in
  wait_until (fun () -> (Pool.stats pool).Pool.waiting = 1);
  Alcotest.(check int) "max live bounded" 2 !(factory.max_live);
  Alcotest.(check int) "opened bounded" 2 (Pool.stats pool).Pool.opened;
  check_exit_ok Alcotest.unit "first" () (Eio.Promise.await first);
  check_exit_ok Alcotest.unit "second" () (Eio.Promise.await second);
  check_exit_ok Alcotest.unit "third" () (Eio.Promise.await third);
  Alcotest.(check int) "still only opened max_size" 2
    (Pool.stats pool).Pool.opened;
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool)

let test_pool_timeout_cleans_waiter_and_preserves_timeout_cause () =
  with_runtime @@ fun rt ->
  let factory = make_pool_factory () in
  let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
  let holder =
    Pool.with_resource pool (fun _ ->
        Effect.delay (Duration.ms 20) Effect.unit)
  in
  let waiter =
    Effect.delay (Duration.ms 1)
      (Pool.with_resource pool (fun _ -> Effect.unit)
      |> Effect.timeout (Duration.ms 2))
  in
  let outcomes = run_ok rt (Effect.all_settled [ holder; waiter ]) in
  let saw_timeout =
    List.exists
      (function Error (Cause.Fail `Timeout) -> true | _ -> false)
      outcomes
  in
  Alcotest.(check bool) "timeout cause" true saw_timeout;
  let stats = Pool.stats pool in
  Alcotest.(check int) "waiting cleaned" 0 stats.Pool.waiting;
  Alcotest.(check int) "cancelled waiter" 1 stats.Pool.cancelled_waiters;
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool)

let test_pool_health_rejection_reopens () =
  with_runtime @@ fun rt ->
  let factory = make_pool_factory ~unhealthy_ids:[ 1 ] () in
  let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
  let id = run_ok rt (Pool.with_resource pool pool_use) in
  Alcotest.(check int) "healthy replacement" 2 id;
  let stats = Pool.stats pool in
  Alcotest.(check int) "opened" 2 stats.Pool.opened;
  Alcotest.(check int) "rejected" 1 stats.Pool.health_rejected;
  Alcotest.(check int) "closed rejected" 1 stats.Pool.closed;
  Alcotest.(check int) "max live bounded" 1 !(factory.max_live);
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool)

let test_pool_acquire_failure_does_not_count_as_active_resource () =
  with_runtime @@ fun rt ->
  let attempts = ref 0 in
  let factory = make_pool_factory () in
  let acquire =
    Effect.sync (fun () -> incr attempts)
    |> Effect.bind (fun () ->
           if !attempts = 1 then Effect.fail `Open_failed else pool_open factory)
  in
  let pool =
    run_ok rt
      (Pool.create ~name:"test.pool" ~kind:"test" ~max_size:1 ~acquire
         ~release:(pool_close factory) ~health_check:pool_health ())
  in
  (match Runtime.run rt (Pool.with_resource pool pool_use) with
  | Exit.Error (Cause.Fail `Open_failed) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected acquire failure, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<pool>")) cause
  | Exit.Ok _ -> Alcotest.fail "expected acquire failure");
  let after_failure = Pool.stats pool in
  Alcotest.(check int) "active after acquire failure" 0 after_failure.Pool.active;
  Alcotest.(check int) "idle after acquire failure" 0 after_failure.Pool.idle;
  ignore (run_ok rt (Pool.with_resource pool pool_use) : int);
  let after_success = Pool.stats pool in
  Alcotest.(check int) "capacity reusable after acquire failure" 1
    after_success.Pool.idle;
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool)

let test_pool_idle_health_failure_rejects_entry () =
  with_runtime @@ fun rt ->
  let factory = make_pool_factory () in
  let fail_health = ref false in
  let health conn =
    if !fail_health && conn.id = 1 then Effect.fail `Health_failed
    else Effect.unit
  in
  let pool =
    run_ok rt (create_test_pool ~max_size:1 ~health_check:health factory)
  in
  let first = run_ok rt (Pool.with_resource pool pool_use) in
  fail_health := true;
  let second = run_ok rt (Pool.with_resource pool pool_use) in
  Alcotest.(check int) "first id" 1 first;
  Alcotest.(check int) "replacement id" 2 second;
  let stats = Pool.stats pool in
  Alcotest.(check int) "opened replacement" 2 stats.Pool.opened;
  Alcotest.(check int) "rejected idle" 1 stats.Pool.health_rejected;
  Alcotest.(check int) "closed rejected idle" 1 stats.Pool.closed;
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool)

let test_pool_idle_health_defect_closes_entry () =
  with_runtime @@ fun rt ->
  let factory = make_pool_factory () in
  let defect_health = ref false in
  let health conn =
    if !defect_health && conn.id = 1 then
      Effect.sync (fun () -> failwith "health defect")
    else Effect.unit
  in
  let pool =
    run_ok rt (create_test_pool ~max_size:1 ~health_check:health factory)
  in
  let first = run_ok rt (Pool.with_resource pool pool_use) in
  defect_health := true;
  (match Runtime.run rt (Pool.with_resource pool pool_use) with
  | Exit.Error (Cause.Die _) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected health defect, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<pool>")) cause
  | Exit.Ok _ -> Alcotest.fail "expected health defect");
  let stats = Pool.stats pool in
  Alcotest.(check int) "first id" 1 first;
  Alcotest.(check int) "closed defective idle" 1 stats.Pool.closed;
  Alcotest.(check int) "not returned to idle" 0 stats.Pool.idle;
  Alcotest.(check int) "no live entries" 0 !(factory.live);
  defect_health := false;
  let replacement = run_ok rt (Pool.with_resource pool pool_use) in
  Alcotest.(check int) "replacement id" 2 replacement;
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool)

let test_pool_cancel_during_health_check_closes_reserved () =
  with_runtime @@ fun rt ->
  let factory = make_pool_factory () in
  let slow_health _ = Effect.delay (Duration.ms 20) Effect.unit in
  let pool =
    run_ok rt (create_test_pool ~max_size:1 ~health_check:slow_health factory)
  in
  (match
     Runtime.run rt
       (Pool.with_resource pool (fun _ -> Effect.unit)
       |> Effect.timeout (Duration.ms 2))
   with
  | Exit.Error (Cause.Fail `Timeout) -> ()
  | _ -> Alcotest.fail "expected timeout during health check");
  wait_until (fun () ->
      let stats = Pool.stats pool in
      stats.Pool.active = 0 && stats.Pool.closed = 1);
  Alcotest.(check int) "live closed" 0 !(factory.live);
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool)

let test_pool_idle_eviction () =
  with_runtime @@ fun rt ->
  let factory = make_pool_factory () in
  let pool =
    run_ok rt
      (create_test_pool ~max_size:1 ~idle_lifetime:(Duration.ms 2)
         ~idle_check_interval:(Duration.ms 1) factory)
  in
  ignore (run_ok rt (Pool.with_resource pool pool_use) : int);
  wait_until (fun () -> (Pool.stats pool).Pool.idle = 1);
  Eio_unix.sleep 0.02;
  wait_until (fun () ->
      let stats = Pool.stats pool in
      stats.Pool.idle = 0 && stats.Pool.closed = 1);
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool)

let test_pool_idle_eviction_continues_after_close_failure () =
  with_runtime @@ fun rt ->
  let factory = make_pool_factory () in
  let release_attempts = ref 0 in
  let release conn =
    Effect.sync (fun () -> incr release_attempts)
    |> Effect.bind (fun () ->
           if !release_attempts = 1 then Effect.fail `Close_failed
           else pool_close factory conn)
  in
  let pool =
    run_ok rt
      (Pool.create ~name:"test.pool" ~kind:"test" ~max_size:1 ~max_idle:1
         ~idle_lifetime:(Duration.ms 2)
         ~idle_check_interval:(Duration.ms 1)
         ~acquire:(pool_open factory) ~release ~health_check:pool_health ())
  in
  ignore (run_ok rt (Pool.with_resource pool pool_use) : int);
  wait_until (fun () -> (Pool.stats pool).Pool.idle = 1);
  Eio_unix.sleep 0.02;
  wait_until (fun () ->
      let stats = Pool.stats pool in
      stats.Pool.idle = 0 && stats.Pool.closed = 1);
  ignore (run_ok rt (Pool.with_resource pool pool_use) : int);
  wait_until (fun () -> (Pool.stats pool).Pool.idle = 1);
  Eio_unix.sleep 0.02;
  wait_until (fun () ->
      let stats = Pool.stats pool in
      stats.Pool.idle = 0 && stats.Pool.closed = 2);
  Alcotest.(check int) "second close reached release" 2 !release_attempts;
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool)

let test_pool_expired_idle_cleanup_preserves_capacity_waiters () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let factory = make_pool_factory () in
  let pool =
    run_ok rt
      (create_test_pool ~max_size:2 ~max_idle:2
         ~idle_lifetime:(Duration.ms 1)
         ~idle_check_interval:(Duration.seconds 60) factory)
  in
  let hold ms =
    Pool.with_resource pool (fun _ -> Effect.delay (Duration.ms ms) Effect.unit)
  in
  let warm_a = fork_run sw rt (hold 5) in
  let warm_b = fork_run sw rt (hold 5) in
  check_exit_ok Alcotest.unit "warm a" () (Eio.Promise.await warm_a);
  check_exit_ok Alcotest.unit "warm b" () (Eio.Promise.await warm_b);
  wait_until (fun () -> (Pool.stats pool).Pool.idle = 2);
  Eio_unix.sleep 0.01;
  let holders = List.init 4 (fun _ -> fork_run sw rt (hold 50)) in
  wait_until (fun () ->
      let stats = Pool.stats pool in
      stats.Pool.active = 2 && stats.Pool.waiting = 2);
  Alcotest.(check int) "max live bounded" 2 !(factory.max_live);
  List.iter
    (fun p -> check_exit_ok Alcotest.unit "holder done" () (Eio.Promise.await p))
    holders;
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool)

let test_pool_expired_idle_close_failure_releases_admission_permit () =
  with_runtime @@ fun rt ->
  let factory = make_pool_factory () in
  let release_calls = ref 0 in
  let release conn =
    Effect.sync (fun () -> incr release_calls)
    |> Effect.bind (fun () -> pool_close factory conn)
    |> Effect.bind (fun () ->
           if !release_calls = 1 then Effect.fail `Close_failed
           else Effect.unit)
  in
  let pool =
    run_ok rt
      (Pool.create ~name:"test.pool" ~kind:"test" ~max_size:1 ~max_idle:1
         ~idle_lifetime:(Duration.ms 1)
         ~idle_check_interval:(Duration.hours 1)
         ~acquire:(pool_open factory) ~release ~health_check:pool_health ())
  in
  ignore (run_ok rt (Pool.with_resource pool pool_use) : int);
  Eio_unix.sleep 0.005;
  let close_failure =
    Pool.with_resource pool (fun _ -> Effect.unit)
    |> Effect.catch (function
         | `Close_failed -> Effect.unit
         | #pool_test_error as err -> Effect.fail err)
  in
  run_ok rt close_failure;
  let checkout_after_failure =
    Pool.with_resource pool (fun _ -> Effect.unit)
    |> Effect.timeout_as (Duration.ms 20) ~on_timeout:`Timeout
  in
  (match Runtime.run rt checkout_after_failure with
  | Exit.Ok () -> ()
  | Exit.Error cause ->
      Alcotest.failf
        "pool permit leaked after expired idle close failure: %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<pool>"))
        cause);
  Alcotest.(check int) "expired close attempted once" 1 !release_calls;
  Alcotest.(check int) "replacement opened" 2 !(factory.opened);
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool)

let test_pool_shutdown_wakes_waiters_and_drains () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let factory = make_pool_factory () in
  let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
  let holder =
    fork_run sw rt
      (Pool.with_resource pool (fun _ ->
           Effect.delay (Duration.ms 20) Effect.unit))
  in
  wait_until (fun () -> (Pool.stats pool).Pool.active = 1);
  let waiter = fork_run sw rt (Pool.with_resource pool (fun _ -> Effect.unit)) in
  wait_until (fun () -> (Pool.stats pool).Pool.waiting = 1);
  let shutdown = fork_run sw rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) in
  (match Eio.Promise.await waiter with
  | Exit.Error (Cause.Fail `Pool_shutdown) -> ()
  | _ -> Alcotest.fail "expected waiter Pool_shutdown");
  check_exit_ok Alcotest.unit "holder done" () (Eio.Promise.await holder);
  check_exit_ok Alcotest.unit "shutdown done" () (Eio.Promise.await shutdown);
  let stats = Pool.stats pool in
  Alcotest.(check int) "active" 0 stats.Pool.active;
  Alcotest.(check int) "idle" 0 stats.Pool.idle;
  Alcotest.(check bool) "shutting down" true stats.Pool.shutting_down;
  Alcotest.(check int) "closed" 1 stats.Pool.closed

let test_pool_shutdown_rejects_waiter_before_permit_release () =
  with_test_clock @@ fun sw clock rt ->
  let factory = make_pool_factory () in
  let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
  let holder =
    fork_run sw rt
      (Pool.with_resource pool (fun _ ->
           Effect.delay (Duration.ms 100) Effect.unit))
  in
  wait_until (fun () -> (Pool.stats pool).Pool.active = 1);
  let waiter = fork_run sw rt (Pool.with_resource pool (fun _ -> Effect.unit)) in
  wait_until (fun () -> (Pool.stats pool).Pool.waiting = 1);
  let shutdown = fork_run sw rt (Pool.shutdown ~deadline:(Duration.ms 500) pool) in
  wait_until (fun () -> (Pool.stats pool).Pool.shutting_down);
  wait_until (fun () -> Eio.Promise.is_resolved waiter);
  Alcotest.(check bool)
    "waiter rejected before active resource releases" true
    (Eio.Promise.is_resolved waiter);
  (match Eio.Promise.await waiter with
  | Exit.Error (Cause.Fail `Pool_shutdown) -> ()
  | _ -> Alcotest.fail "expected waiter Pool_shutdown");
  Test_clock.adjust clock (Duration.ms 100);
  check_exit_ok Alcotest.unit "holder done" () (Eio.Promise.await holder);
  check_exit_ok Alcotest.unit "shutdown done" () (Eio.Promise.await shutdown)

let test_pool_shutdown_waits_for_active_close () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let factory = make_pool_factory () in
  let close_started = ref false in
  let release conn =
    Effect.sync (fun () -> close_started := true)
    |> Effect.bind (fun () -> Effect.delay (Duration.ms 30) Effect.unit)
    |> Effect.bind (fun () -> pool_close factory conn)
  in
  let pool =
    run_ok rt
      (Pool.create ~name:"test.pool" ~kind:"test" ~max_size:1
         ~acquire:(pool_open factory) ~release ~health_check:pool_health ())
  in
  let holder =
    fork_run sw rt
      (Pool.with_resource pool (fun _ ->
           Effect.delay (Duration.ms 1) Effect.unit))
  in
  wait_until (fun () -> (Pool.stats pool).Pool.active = 1);
  let shutdown = fork_run sw rt (Pool.shutdown ~deadline:(Duration.ms 200) pool) in
  wait_until (fun () -> !close_started);
  Eio_unix.sleep 0.005;
  Alcotest.(check bool)
    "shutdown waits for close" false
    (Eio.Promise.is_resolved shutdown);
  check_exit_ok Alcotest.unit "holder done" () (Eio.Promise.await holder);
  check_exit_ok Alcotest.unit "shutdown done" () (Eio.Promise.await shutdown);
  Alcotest.(check int) "closed" 1 !(factory.closed)

let test_pool_shutdown_deadline_timeout () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let factory = make_pool_factory () in
  let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
  let holder =
    fork_run sw rt
      (Pool.with_resource pool (fun _ ->
           Effect.delay (Duration.ms 30) Effect.unit))
  in
  wait_until (fun () -> (Pool.stats pool).Pool.active = 1);
  (match Runtime.run rt (Pool.shutdown ~deadline:(Duration.ms 2) pool) with
  | Exit.Error (Cause.Fail `Pool_shutdown_timeout) -> ()
  | _ -> Alcotest.fail "expected shutdown timeout");
  check_exit_ok Alcotest.unit "holder done" () (Eio.Promise.await holder);
  wait_until (fun () -> (Pool.stats pool).Pool.closed = 1)

let test_pool_shutdown_deadline_waits_for_idle_close () =
  with_test_clock @@ fun sw clock rt ->
  let factory = make_pool_factory () in
  let release_started, release_started_resolver = Eio.Promise.create () in
  let release_continue, release_continue_resolver = Eio.Promise.create () in
  let release conn =
    Effect.sync (fun () ->
        ignore (Eio.Promise.try_resolve release_started_resolver ());
        Eio.Promise.await release_continue)
    |> Effect.bind (fun () -> pool_close factory conn)
  in
  let pool =
    run_ok rt
      (Pool.create ~name:"test.pool" ~kind:"test" ~max_size:1
         ~acquire:(pool_open factory) ~release ~health_check:pool_health ())
  in
  ignore (run_ok rt (Pool.with_resource pool pool_use) : int);
  wait_until (fun () -> (Pool.stats pool).Pool.idle = 1);
  let shutdown = fork_run sw rt (Pool.shutdown ~deadline:(Duration.ms 5) pool) in
  Eio.Promise.await release_started;
  let while_closing = Pool.stats pool in
  Alcotest.(check int) "idle removed while release is closing" 0
    while_closing.Pool.idle;
  Alcotest.(check int) "not counted closed before release completes" 0
    while_closing.Pool.closed;
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  Eio.Fiber.yield ();
  Alcotest.(check bool) "shutdown waits for idle close" false
    (Eio.Promise.is_resolved shutdown);
  Alcotest.(check int) "factory did not close before release completes" 0
    !(factory.closed);
  Eio.Promise.resolve release_continue_resolver ();
  check_exit_ok Alcotest.unit "shutdown closes idle" ()
    (Eio.Promise.await shutdown);
  let after_shutdown = Pool.stats pool in
  Alcotest.(check int) "idle removed after close" 0 after_shutdown.Pool.idle;
  Alcotest.(check int) "closed after shutdown" 1 after_shutdown.Pool.closed;
  Alcotest.(check int) "factory closed after shutdown" 1 !(factory.closed)

let set_pool_active_for_invariant_test pool active =
  Obj.set_field (Obj.repr pool) 17 (Obj.repr active)

let test_pool_release_detects_active_underflow () =
  with_runtime @@ fun rt ->
  let factory = make_pool_factory () in
  let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
  let result =
    Runtime.run rt
      (Pool.with_resource pool (fun _ ->
           Effect.sync (fun () -> set_pool_active_for_invariant_test pool 0)))
  in
  (match result with
  | Exit.Error
      (Cause.Finalizer
        (Cause.Finalizer.Die { exn = Invalid_argument message; _ })) ->
      Alcotest.(check string)
        "invariant message"
        "Eta.Pool invariant violated: active underflow"
        message
  | Exit.Error cause ->
      Alcotest.failf "expected pool invariant Die, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<pool>"))
        cause
  | Exit.Ok () -> Alcotest.fail "expected pool invariant failure");
  set_pool_active_for_invariant_test pool 0

let test_pool_observability_signals () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let meter = Meter.in_memory () in
  let logger = Logger.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer)
      ~meter:(Meter.as_capability meter)
      ~logger:(Logger.as_capability logger) ()
  in
  let factory = make_pool_factory ~unhealthy_ids:[ 1 ] () in
  let pool =
    run_ok rt
      (Pool.create ~name:"obs.pool" ~kind:"sql.client" ~max_size:1
         ~acquire:(pool_open factory) ~release:(pool_close factory)
         ~health_check:pool_health ())
  in
  ignore (run_ok rt (Pool.with_resource pool pool_use) : int);
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool);
  let metric_names = List.map (fun p -> p.Meter.name) (Meter.dump meter) in
  let has_metric name = List.exists (String.equal name) metric_names in
  Alcotest.(check bool) "active metric" true (has_metric "eta.pool.active");
  Alcotest.(check bool) "opened metric" true (has_metric "eta.pool.opened");
  Alcotest.(check bool) "closed metric" true (has_metric "eta.pool.closed");
  Alcotest.(check bool)
    "health metric" true (has_metric "eta.pool.health_rejected");
  let span_names = List.map (fun s -> s.Tracer.name) (Tracer.dump tracer) in
  let has_span name = List.exists (String.equal name) span_names in
  Alcotest.(check bool) "acquire span" true (has_span "eta.pool.acquire");
  Alcotest.(check bool) "health span" true (has_span "eta.pool.health_check");
  Alcotest.(check bool) "close span" true (has_span "eta.pool.close");
  Alcotest.(check bool) "shutdown span" true (has_span "eta.pool.shutdown");
  let log_bodies = List.map (fun r -> r.Logger.body) (Logger.dump logger) in
  Alcotest.(check bool) "health log" true
    (List.exists (String.equal "eta.pool.health_rejected") log_bodies);
  Alcotest.(check bool) "shutdown log" true
    (List.exists (String.equal "eta.pool.shutdown_started") log_bodies)
