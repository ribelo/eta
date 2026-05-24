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

let test_pool_shutdown_wakes_waiters_and_drains () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
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

let test_pool_shutdown_deadline_timeout () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
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

let test_pool_observability_signals () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let meter = Meter.in_memory () in
  let logger = Logger.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
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


