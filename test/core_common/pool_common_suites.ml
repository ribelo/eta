module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  open Eta

  module E = Effect

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

  let pp_hidden ppf _ = Format.pp_print_string ppf "<pool>"

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

  let expect_fail label pred = function
    | Exit.Error (Cause.Fail err) when pred err -> ()
    | Exit.Error cause ->
        Alcotest.failf "%s: expected typed failure, got %a" label
          (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.failf "%s: expected typed failure, got Ok" label

  let expect_die = function
    | Exit.Error (Cause.Die _) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected Die, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected Die"

  let expect_interrupt label = function
    | Exit.Error cause when Cause.is_interrupt_only cause -> ()
    | Exit.Error cause ->
        Alcotest.failf "%s: expected interrupt, got %a" label
          (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.failf "%s: expected interrupt, got Ok" label

  let runtime_interrupt_effect () =
    Effect.Expert.make ~leaf_name:"test.interrupt" @@ fun context ->
    let contract = Effect.Expert.contract context in
    contract.Eta.Runtime_contract.cancel_sub @@ fun cancel_context ->
    contract.Eta.Runtime_contract.cancel cancel_context Exit;
    contract.Eta.Runtime_contract.await_cancel ()

  let wait_until ?(attempts = 300) pred =
    let rec loop n =
      if pred () then ()
      else if n = 0 then Alcotest.fail "condition did not become true"
      else (
        B.yield ();
        loop (n - 1))
    in
    loop attempts

  let wait_for_sleepers clock expected =
    wait_until (fun () -> B.sleeper_count clock >= expected)

  let wait_until_pool_stats ?(attempts = 300) pool pred =
    let rec loop n =
      let stats = Pool.stats pool in
      if pred stats then ()
      else if n = 0 then
        Alcotest.failf
          "condition did not become true: active=%d idle=%d waiting=%d opened=%d closed=%d invalidated=%d"
          stats.Pool.active stats.Pool.idle stats.Pool.waiting
          stats.Pool.opened stats.Pool.closed stats.Pool.invalidated
      else (
        B.yield ();
        loop (n - 1))
    in
    loop attempts

  let advance_clock_until_resolved ?(step = Duration.ms 1) clock promise limit =
    let rec loop remaining =
      if B.is_resolved promise then ()
      else if remaining = 0 then Alcotest.fail "effect did not complete"
      else (
        B.adjust_clock clock step;
        B.yield ();
        loop (remaining - 1))
    in
    loop limit

  let advance_clock_until_all_resolved ?(step = Duration.ms 1) clock promises
      limit =
    let rec loop remaining =
      if List.for_all B.is_resolved promises then ()
      else if remaining = 0 then Alcotest.fail "effects did not complete"
      else (
        B.adjust_clock clock step;
        B.yield ();
        loop (remaining - 1))
    in
    loop limit

  let make_pool_factory ?(unhealthy_ids = []) () =
    {
      next_id = ref 0;
      opened = ref 0;
      closed = ref 0;
      live = ref 0;
      max_live = ref 0;
      unhealthy_ids;
    }

  let pool_open (factory : pool_test_factory) :
      (pool_test_conn, pool_test_error) E.t =
    E.sync @@ fun () ->
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
      (unit, pool_test_error) E.t =
    E.sync @@ fun () ->
    if not !(conn.closed) then (
      conn.closed := true;
      incr factory.closed;
      decr factory.live)

  let pool_health (conn : pool_test_conn) : (unit, pool_test_error) E.t =
    if !(conn.unhealthy) then E.fail `Health_failed else E.unit

  let pool_use (conn : pool_test_conn) : (int, pool_test_error) E.t =
    E.sync @@ fun () ->
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

  let shutdown_pool_with_test_clock clock rt pool =
    ignore (B.run rt (Pool.shutdown ~deadline:(Duration.ms 100) pool)
      : (unit, pool_test_error) Exit.t);
    B.adjust_clock clock (Duration.hours 1);
    B.yield ()

  let set_pool_active_for_invariant_test pool active =
    Obj.set_field (Obj.repr pool) 17 (Obj.repr active)

  let test_pool_reuses_idle_lifo () =
    B.with_runtime @@ fun _ctx rt ->
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
    ignore (run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) : unit);
    Alcotest.(check int) "closed on shutdown" 1 !(factory.closed)

  let test_pool_with_resource_body_success_releases_resource () =
    B.with_runtime @@ fun _ctx rt ->
    let factory = make_pool_factory () in
    let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
    Alcotest.(check int) "result" 1
      (run_ok rt (Pool.with_resource pool pool_use));
    let stats = Pool.stats pool in
    Alcotest.(check int) "active" 0 stats.Pool.active;
    Alcotest.(check int) "idle" 1 stats.Pool.idle;
    Alcotest.(check int) "not invalidated" 0 stats.Pool.invalidated;
    ignore (run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) : unit)

  let test_pool_with_resource_body_typed_failure_releases_resource () =
    B.with_runtime @@ fun _ctx rt ->
    let factory = make_pool_factory () in
    let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
    B.run rt (Pool.with_resource pool (fun _ -> E.fail `Open_failed))
    |> expect_fail "body typed failure" (( = ) `Open_failed);
    let stats = Pool.stats pool in
    Alcotest.(check int) "active" 0 stats.Pool.active;
    Alcotest.(check int) "idle" 1 stats.Pool.idle;
    Alcotest.(check int) "not invalidated" 0 stats.Pool.invalidated;
    ignore (run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) : unit)

  let test_pool_with_resource_body_defect_releases_resource () =
    B.with_runtime @@ fun _ctx rt ->
    let factory = make_pool_factory () in
    let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
    B.run rt
      (Pool.with_resource pool (fun _ ->
           E.sync (fun () -> failwith "body defect")))
    |> expect_die;
    let stats = Pool.stats pool in
    Alcotest.(check int) "active" 0 stats.Pool.active;
    Alcotest.(check int) "idle" 1 stats.Pool.idle;
    Alcotest.(check int) "not invalidated" 0 stats.Pool.invalidated;
    ignore (run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) : unit)

  let test_pool_with_resource_body_interruption_releases_without_invalidation () =
    B.with_runtime @@ fun _ctx rt ->
    let factory = make_pool_factory () in
    let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
    B.run rt (Pool.with_resource pool (fun _ -> runtime_interrupt_effect ()))
    |> expect_interrupt "body interruption";
    let stats = Pool.stats pool in
    Alcotest.(check int) "active" 0 stats.Pool.active;
    Alcotest.(check int) "idle" 1 stats.Pool.idle;
    Alcotest.(check int) "closed" 0 stats.Pool.closed;
    Alcotest.(check int) "not invalidated" 0 stats.Pool.invalidated;
    ignore (run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) : unit)

  let test_pool_lease_invalidation_closes_on_release_and_replaces () =
    B.with_runtime @@ fun _ctx rt ->
    let factory = make_pool_factory () in
    let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
    let first =
      run_ok rt
        (Pool.with_lease pool (fun lease ->
             let conn = Pool.Lease.resource lease in
             Pool.Lease.invalidate lease |> E.map (fun () -> conn.id)))
    in
    Alcotest.(check int) "invalidated id" 1 first;
    let after_invalidated = Pool.stats pool in
    Alcotest.(check int) "active" 0 after_invalidated.Pool.active;
    Alcotest.(check int) "idle" 0 after_invalidated.Pool.idle;
    Alcotest.(check int) "closed" 1 after_invalidated.Pool.closed;
    Alcotest.(check int) "invalidated" 1 after_invalidated.Pool.invalidated;
    Alcotest.(check int)
      "health not rejected" 0 after_invalidated.Pool.health_rejected;
    Alcotest.(check int) "factory closed" 1 !(factory.closed);
    Alcotest.(check int) "factory live" 0 !(factory.live);
    let second = run_ok rt (Pool.with_resource pool pool_use) in
    Alcotest.(check int) "replacement id" 2 second;
    let after_replacement = Pool.stats pool in
    Alcotest.(check int) "opened replacement" 2 after_replacement.Pool.opened;
    Alcotest.(check int) "idle replacement" 1 after_replacement.Pool.idle;
    ignore (run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) : unit)

  let test_pool_lease_invalidation_is_idempotent () =
    B.with_runtime @@ fun _ctx rt ->
    let factory = make_pool_factory () in
    let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
    run_ok rt
      (Pool.with_lease pool (fun lease ->
           Pool.Lease.invalidate lease
           |> E.bind (fun () -> Pool.Lease.invalidate lease)
           |> E.bind (fun () -> Pool.Lease.invalidate lease)));
    let stats = Pool.stats pool in
    Alcotest.(check int) "closed once" 1 stats.Pool.closed;
    Alcotest.(check int) "invalidated once" 1 stats.Pool.invalidated;
    Alcotest.(check int) "health not rejected" 0 stats.Pool.health_rejected;
    Alcotest.(check int) "factory closed once" 1 !(factory.closed);
    Alcotest.(check int) "factory live" 0 !(factory.live);
    let replacement = run_ok rt (Pool.with_resource pool pool_use) in
    Alcotest.(check int) "replacement id" 2 replacement;
    ignore (run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) : unit)

  let test_pool_lease_invalidation_preserves_typed_failure () =
    B.with_runtime @@ fun _ctx rt ->
    let factory = make_pool_factory () in
    let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
    B.run rt
      (Pool.with_lease pool (fun lease ->
           Pool.Lease.invalidate lease |> E.bind (fun () -> E.fail `Open_failed)))
    |> expect_fail "invalidated typed failure" (( = ) `Open_failed);
    let stats = Pool.stats pool in
    Alcotest.(check int) "active" 0 stats.Pool.active;
    Alcotest.(check int) "idle" 0 stats.Pool.idle;
    Alcotest.(check int) "closed" 1 stats.Pool.closed;
    Alcotest.(check int) "invalidated" 1 stats.Pool.invalidated;
    let replacement = run_ok rt (Pool.with_resource pool pool_use) in
    Alcotest.(check int) "replacement id" 2 replacement;
    ignore (run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) : unit)

  let test_pool_lease_invalidation_preserves_defect () =
    B.with_runtime @@ fun _ctx rt ->
    let factory = make_pool_factory () in
    let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
    B.run rt
      (Pool.with_lease pool (fun lease ->
           Pool.Lease.invalidate lease
           |> E.bind (fun () -> E.sync (fun () -> failwith "body defect"))))
    |> expect_die;
    let stats = Pool.stats pool in
    Alcotest.(check int) "active" 0 stats.Pool.active;
    Alcotest.(check int) "idle" 0 stats.Pool.idle;
    Alcotest.(check int) "closed" 1 stats.Pool.closed;
    Alcotest.(check int) "invalidated" 1 stats.Pool.invalidated;
    let replacement = run_ok rt (Pool.with_resource pool pool_use) in
    Alcotest.(check int) "replacement id" 2 replacement;
    ignore (run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) : unit)

  let test_pool_lease_invalidation_preserves_interruption () =
    B.with_runtime @@ fun _ctx rt ->
    let factory = make_pool_factory () in
    let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
    B.run rt
      (Pool.with_lease pool (fun lease ->
           Pool.Lease.invalidate lease
           |> E.bind (fun () -> runtime_interrupt_effect ())))
    |> expect_interrupt "invalidated interruption";
    let stats = Pool.stats pool in
    Alcotest.(check int) "active" 0 stats.Pool.active;
    Alcotest.(check int) "idle" 0 stats.Pool.idle;
    Alcotest.(check int) "closed" 1 stats.Pool.closed;
    Alcotest.(check int) "invalidated" 1 stats.Pool.invalidated;
    let replacement = run_ok rt (Pool.with_resource pool pool_use) in
    Alcotest.(check int) "replacement id" 2 replacement;
    ignore (run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) : unit)

  let test_pool_lease_invalidation_reports_close_failure () =
    B.with_runtime @@ fun _ctx rt ->
    let factory = make_pool_factory () in
    let release_calls = ref 0 in
    let release conn =
      E.sync (fun () -> incr release_calls)
      |> E.bind (fun () -> pool_close factory conn)
      |> E.bind (fun () -> E.fail `Close_failed)
    in
    let pool =
      run_ok rt
        (Pool.create ~name:"test.pool" ~kind:"test" ~max_size:1
           ~acquire:(pool_open factory) ~release ~health_check:pool_health ())
    in
    (match
       B.run rt (Pool.with_lease pool (fun lease -> Pool.Lease.invalidate lease))
     with
    | Exit.Error (Cause.Finalizer (Cause.Finalizer.Fail _)) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected invalidated close failure, got %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok () -> Alcotest.fail "expected invalidated close failure");
    let stats = Pool.stats pool in
    Alcotest.(check int) "active" 0 stats.Pool.active;
    Alcotest.(check int) "idle" 0 stats.Pool.idle;
    Alcotest.(check int) "closed accounted" 1 stats.Pool.closed;
    Alcotest.(check int) "invalidated" 1 stats.Pool.invalidated;
    Alcotest.(check int) "release called once" 1 !release_calls;
    Alcotest.(check int) "factory closed once" 1 !(factory.closed)

  let test_pool_lease_invalidation_during_shutdown_closes_once () =
    B.with_test_clock @@ fun ctx clock rt ->
    let factory = make_pool_factory () in
    let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
    let holder =
      B.fork_run ctx rt
        (Pool.with_lease pool (fun lease ->
             Pool.Lease.invalidate lease
             |> E.bind (fun () -> E.delay (Duration.ms 10) E.unit)))
    in
    wait_until_pool_stats pool (fun stats ->
        stats.Pool.active = 1 && stats.Pool.invalidated = 1);
    let shutdown =
      B.fork_run ctx rt (Pool.shutdown ~deadline:(Duration.ms 100) pool)
    in
    wait_until_pool_stats pool (fun stats -> stats.Pool.shutting_down);
    advance_clock_until_all_resolved clock [ holder; shutdown ] 200;
    check_exit_ok Alcotest.unit "holder done" () (B.await holder);
    check_exit_ok Alcotest.unit "shutdown done" () (B.await shutdown);
    let stats = Pool.stats pool in
    Alcotest.(check int) "active" 0 stats.Pool.active;
    Alcotest.(check int) "idle" 0 stats.Pool.idle;
    Alcotest.(check int) "waiting" 0 stats.Pool.waiting;
    Alcotest.(check int) "closed once" 1 stats.Pool.closed;
    Alcotest.(check int) "invalidated once" 1 stats.Pool.invalidated;
    Alcotest.(check int) "factory closed once" 1 !(factory.closed);
    Alcotest.(check int) "factory live" 0 !(factory.live)

  let test_pool_release_defect_releases_capacity () =
    B.with_test_clock @@ fun ctx clock rt ->
    let factory = make_pool_factory () in
    let release_attempts = ref 0 in
    let release conn =
      E.sync (fun () -> incr release_attempts)
      |> E.bind (fun () -> pool_close factory conn)
      |> E.bind (fun () ->
             if !release_attempts = 1 then
               E.sync (fun () -> failwith "release defect")
             else E.unit)
    in
    let pool =
      run_ok rt
        (Pool.create ~name:"test.pool" ~kind:"test" ~max_size:1 ~max_idle:0
           ~acquire:(pool_open factory) ~release ~health_check:pool_health ())
    in
    (match B.run rt (Pool.with_resource pool (fun _ -> E.unit)) with
    | Exit.Error (Cause.Finalizer (Cause.Finalizer.Die _)) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected release defect, got %a" (Cause.pp pp_hidden)
          cause
    | Exit.Ok () -> Alcotest.fail "expected release defect");
    let after_defect = Pool.stats pool in
    Alcotest.(check int) "active after release defect" 0 after_defect.Pool.active;
    Alcotest.(check int) "closed after release defect" 1 after_defect.Pool.closed;
    let replacement =
      Pool.with_resource pool pool_use
      |> E.timeout_as (Duration.ms 20) ~on_timeout:`Timeout
    in
    let replacement_result = B.fork_run ctx rt replacement in
    advance_clock_until_resolved clock replacement_result 20;
    Alcotest.(check int) "capacity reusable after release defect" 2
      (match B.await replacement_result with
      | Exit.Ok value -> value
      | Exit.Error cause ->
          Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause);
    shutdown_pool_with_test_clock clock rt pool

  let test_pool_shutdown_release_defect_removes_idle_entry () =
    B.with_runtime @@ fun _ctx rt ->
    let pool =
      run_ok rt
        (Pool.create ~name:"defective-close" ~max_size:1 ~acquire:(E.pure ())
           ~release:(fun () -> E.sync (fun () -> failwith "close boom"))
           ())
    in
    ignore (run_ok rt (Pool.with_resource pool (fun () -> E.unit)) : unit);
    B.run rt (Pool.shutdown pool) |> expect_die;
    let stats = Pool.stats pool in
    Alcotest.(check int) "idle removed after failed close" 0 stats.Pool.idle;
    Alcotest.(check int) "close was accounted" 1 stats.Pool.closed

  let test_pool_health_rejection_reopens () =
    B.with_runtime @@ fun _ctx rt ->
    let factory = make_pool_factory ~unhealthy_ids:[ 1 ] () in
    let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
    let id = run_ok rt (Pool.with_resource pool pool_use) in
    Alcotest.(check int) "healthy replacement" 2 id;
    let stats = Pool.stats pool in
    Alcotest.(check int) "opened" 2 stats.Pool.opened;
    Alcotest.(check int) "rejected" 1 stats.Pool.health_rejected;
    Alcotest.(check int) "closed rejected" 1 stats.Pool.closed;
    Alcotest.(check int) "max live bounded" 1 !(factory.max_live);
    ignore (run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) : unit)

  let test_pool_acquire_failure_does_not_count_as_active_resource () =
    B.with_runtime @@ fun _ctx rt ->
    let attempts = ref 0 in
    let factory = make_pool_factory () in
    let acquire =
      E.sync (fun () -> incr attempts)
      |> E.bind (fun () ->
             if !attempts = 1 then E.fail `Open_failed else pool_open factory)
    in
    let pool =
      run_ok rt
        (Pool.create ~name:"test.pool" ~kind:"test" ~max_size:1 ~acquire
           ~release:(pool_close factory) ~health_check:pool_health ())
    in
    B.run rt (Pool.with_resource pool pool_use)
    |> expect_fail "acquire failure" (( = ) `Open_failed);
    let after_failure = Pool.stats pool in
    Alcotest.(check int) "active after acquire failure" 0
      after_failure.Pool.active;
    Alcotest.(check int) "idle after acquire failure" 0 after_failure.Pool.idle;
    ignore (run_ok rt (Pool.with_resource pool pool_use) : int);
    let after_success = Pool.stats pool in
    Alcotest.(check int) "capacity reusable after acquire failure" 1
      after_success.Pool.idle;
    ignore (run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) : unit)

  let test_pool_idle_health_failure_rejects_entry () =
    B.with_runtime @@ fun _ctx rt ->
    let factory = make_pool_factory () in
    let fail_health = ref false in
    let health conn =
      if !fail_health && conn.id = 1 then E.fail `Health_failed else E.unit
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
    ignore (run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) : unit)

  let test_pool_idle_health_defect_closes_entry () =
    B.with_runtime @@ fun _ctx rt ->
    let factory = make_pool_factory () in
    let defect_health = ref false in
    let health conn =
      if !defect_health && conn.id = 1 then
        E.sync (fun () -> failwith "health defect")
      else E.unit
    in
    let pool =
      run_ok rt (create_test_pool ~max_size:1 ~health_check:health factory)
    in
    let first = run_ok rt (Pool.with_resource pool pool_use) in
    defect_health := true;
    B.run rt (Pool.with_resource pool pool_use) |> expect_die;
    let stats = Pool.stats pool in
    Alcotest.(check int) "first id" 1 first;
    Alcotest.(check int) "closed defective idle" 1 stats.Pool.closed;
    Alcotest.(check int) "not returned to idle" 0 stats.Pool.idle;
    Alcotest.(check int) "no live entries" 0 !(factory.live);
    defect_health := false;
    let replacement = run_ok rt (Pool.with_resource pool pool_use) in
    Alcotest.(check int) "replacement id" 2 replacement;
    ignore (run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) : unit)

  let test_pool_cancel_during_health_check_closes_reserved () =
    B.with_test_clock @@ fun ctx clock rt ->
    let factory = make_pool_factory () in
    let slow_health _ = E.delay (Duration.ms 20) E.unit in
    let pool =
      run_ok rt (create_test_pool ~max_size:1 ~health_check:slow_health factory)
    in
    let promise =
      B.fork_run ctx rt
        (Pool.with_resource pool (fun _ -> E.unit)
        |> E.timeout (Duration.ms 2))
    in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 2);
    B.await promise |> expect_fail "timeout during health check" (( = ) `Timeout);
    wait_until (fun () ->
        let stats = Pool.stats pool in
        stats.Pool.active = 0 && stats.Pool.closed = 1);
    Alcotest.(check int) "live closed" 0 !(factory.live);
    ignore (run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) : unit)

  let test_pool_max_size_respected_under_concurrent_checkout () =
    B.with_test_clock @@ fun ctx clock rt ->
    let factory = make_pool_factory () in
    let pool = run_ok rt (create_test_pool ~max_size:2 factory) in
    let use_for ms =
      Pool.with_resource pool (fun _ -> E.delay (Duration.ms ms) E.unit)
    in
    let first = B.fork_run ctx rt (use_for 30) in
    let second = B.fork_run ctx rt (use_for 30) in
    wait_until (fun () ->
        let stats = Pool.stats pool in
        stats.Pool.active = 2 && stats.Pool.opened = 2);
    let third = B.fork_run ctx rt (use_for 1) in
    wait_until (fun () -> (Pool.stats pool).Pool.waiting = 1);
    Alcotest.(check int) "max live bounded" 2 !(factory.max_live);
    Alcotest.(check int) "opened bounded" 2 (Pool.stats pool).Pool.opened;
    B.adjust_clock clock (Duration.ms 30);
    check_exit_ok Alcotest.unit "first" () (B.await first);
    check_exit_ok Alcotest.unit "second" () (B.await second);
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 1);
    check_exit_ok Alcotest.unit "third" () (B.await third);
    Alcotest.(check int) "still only opened max_size" 2
      (Pool.stats pool).Pool.opened;
    ignore (run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) : unit)

  let test_pool_timeout_cleans_waiter_and_preserves_timeout_cause () =
    B.with_test_clock @@ fun ctx clock rt ->
    let factory = make_pool_factory () in
    let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
    let holder =
      Pool.with_resource pool (fun _ ->
          E.delay (Duration.ms 20) E.unit)
    in
    let waiter =
      E.delay (Duration.ms 1)
        (Pool.with_resource pool (fun _ -> E.unit)
        |> E.timeout (Duration.ms 2))
    in
    let promise = B.fork_run ctx rt (E.all_settled [ holder; waiter ]) in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 1);
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 2);
    B.adjust_clock clock (Duration.ms 17);
    let outcomes =
      match B.await promise with
      | Exit.Ok outcomes -> outcomes
      | Exit.Error cause ->
          Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause
    in
    let saw_timeout =
      List.exists
        (function Error (Cause.Fail `Timeout) -> true | _ -> false)
        outcomes
    in
    Alcotest.(check bool) "timeout cause" true saw_timeout;
    let stats = Pool.stats pool in
    Alcotest.(check int) "waiting cleaned" 0 stats.Pool.waiting;
    Alcotest.(check int) "cancelled waiter" 1 stats.Pool.cancelled_waiters;
    ignore (run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) : unit)

  let test_pool_shutdown_wakes_waiters_and_drains () =
    B.with_test_clock @@ fun ctx clock rt ->
    let factory = make_pool_factory () in
    let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
    let holder =
      B.fork_run ctx rt
        (Pool.with_resource pool (fun _ ->
             E.delay (Duration.ms 20) E.unit))
    in
    wait_until (fun () -> (Pool.stats pool).Pool.active = 1);
    let waiter =
      B.fork_run ctx rt (Pool.with_resource pool (fun _ -> E.unit))
    in
    wait_until (fun () -> (Pool.stats pool).Pool.waiting = 1);
    let shutdown =
      B.fork_run ctx rt (Pool.shutdown ~deadline:(Duration.ms 100) pool)
    in
    begin match B.await waiter with
    | Exit.Error (Cause.Fail `Pool_shutdown) -> ()
    | _ -> Alcotest.fail "expected waiter Pool_shutdown"
    end;
    B.adjust_clock clock (Duration.ms 20);
    check_exit_ok Alcotest.unit "holder done" () (B.await holder);
    check_exit_ok Alcotest.unit "shutdown done" () (B.await shutdown);
    let stats = Pool.stats pool in
    Alcotest.(check int) "active" 0 stats.Pool.active;
    Alcotest.(check int) "idle" 0 stats.Pool.idle;
    Alcotest.(check bool) "shutting down" true stats.Pool.shutting_down;
    Alcotest.(check int) "closed" 1 stats.Pool.closed

  let test_pool_shutdown_rejects_waiter_before_permit_release () =
    B.with_test_clock @@ fun ctx clock rt ->
    let factory = make_pool_factory () in
    let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
    let holder =
      B.fork_run ctx rt
        (Pool.with_resource pool (fun _ ->
             E.delay (Duration.ms 100) E.unit))
    in
    wait_until (fun () -> (Pool.stats pool).Pool.active = 1);
    let waiter =
      B.fork_run ctx rt (Pool.with_resource pool (fun _ -> E.unit))
    in
    wait_until (fun () -> (Pool.stats pool).Pool.waiting = 1);
    let shutdown =
      B.fork_run ctx rt (Pool.shutdown ~deadline:(Duration.ms 500) pool)
    in
    wait_until (fun () -> (Pool.stats pool).Pool.shutting_down);
    wait_until (fun () -> B.is_resolved waiter);
    Alcotest.(check bool)
      "waiter rejected before active resource releases" true
      (B.is_resolved waiter);
    (match B.await waiter with
    | Exit.Error (Cause.Fail `Pool_shutdown) -> ()
    | _ -> Alcotest.fail "expected waiter Pool_shutdown");
    B.adjust_clock clock (Duration.ms 100);
    check_exit_ok Alcotest.unit "holder done" () (B.await holder);
    advance_clock_until_resolved clock shutdown 100;
    check_exit_ok Alcotest.unit "shutdown done" () (B.await shutdown)

  let test_pool_shutdown_deadline_timeout () =
    B.with_test_clock @@ fun ctx clock rt ->
    let factory = make_pool_factory () in
    let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
    let holder =
      B.fork_run ctx rt
        (Pool.with_resource pool (fun _ ->
             E.delay (Duration.ms 30) E.unit))
    in
    wait_until (fun () -> (Pool.stats pool).Pool.active = 1);
    let shutdown =
      B.fork_run ctx rt (Pool.shutdown ~deadline:(Duration.ms 2) pool)
    in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 2);
    (match B.await shutdown with
    | Exit.Error (Cause.Fail `Pool_shutdown_timeout) -> ()
    | _ -> Alcotest.fail "expected shutdown timeout");
    B.adjust_clock clock (Duration.ms 30);
    check_exit_ok Alcotest.unit "holder done" () (B.await holder);
    wait_until (fun () -> (Pool.stats pool).Pool.closed = 1)

  let test_pool_shutdown_waits_for_active_close () =
    B.with_test_clock @@ fun ctx clock rt ->
    let factory = make_pool_factory () in
    let close_started = ref false in
    let release conn =
      E.sync (fun () -> close_started := true)
      |> E.bind (fun () -> E.delay (Duration.ms 30) E.unit)
      |> E.bind (fun () -> pool_close factory conn)
    in
    let pool =
      run_ok rt
        (Pool.create ~name:"test.pool" ~kind:"test" ~max_size:1
           ~acquire:(pool_open factory) ~release ~health_check:pool_health ())
    in
    let holder =
      B.fork_run ctx rt
        (Pool.with_resource pool (fun _ ->
             E.delay (Duration.ms 1) E.unit))
    in
    wait_until (fun () -> (Pool.stats pool).Pool.active = 1);
    let shutdown =
      B.fork_run ctx rt (Pool.shutdown ~deadline:(Duration.ms 200) pool)
    in
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 1);
    wait_until (fun () -> !close_started);
    B.yield ();
    Alcotest.(check bool) "shutdown waits for close" false
      (B.is_resolved shutdown);
    B.adjust_clock clock (Duration.ms 30);
    check_exit_ok Alcotest.unit "holder done" () (B.await holder);
    advance_clock_until_resolved clock shutdown 100;
    check_exit_ok Alcotest.unit "shutdown done" () (B.await shutdown);
    Alcotest.(check int) "closed" 1 !(factory.closed)

  let test_pool_shutdown_deadline_waits_for_idle_close () =
    B.with_test_clock @@ fun ctx clock rt ->
    let factory = make_pool_factory () in
    let release_started, release_started_resolver = B.create_promise () in
    let release_continue, release_continue_resolver = B.create_promise () in
    let release conn =
      E.sync (fun () -> B.try_resolve release_started_resolver ())
      |> E.bind (fun () -> B.await_effect release_continue)
      |> E.bind (fun () -> pool_close factory conn)
    in
    let pool =
      run_ok rt
        (Pool.create ~name:"test.pool" ~kind:"test" ~max_size:1
           ~acquire:(pool_open factory) ~release ~health_check:pool_health ())
    in
    ignore (run_ok rt (Pool.with_resource pool pool_use) : int);
    wait_until (fun () -> (Pool.stats pool).Pool.idle = 1);
    let shutdown =
      B.fork_run ctx rt (Pool.shutdown ~deadline:(Duration.ms 5) pool)
    in
    ignore (B.await release_started : unit);
    let while_closing = Pool.stats pool in
    Alcotest.(check int) "idle removed while release is closing" 0
      while_closing.Pool.idle;
    Alcotest.(check int) "not counted closed before release completes" 0
      while_closing.Pool.closed;
    B.adjust_clock clock (Duration.ms 5);
    B.yield ();
    Alcotest.(check bool) "shutdown waits for idle close" false
      (B.is_resolved shutdown);
    Alcotest.(check int) "factory did not close before release completes" 0
      !(factory.closed);
    B.resolve release_continue_resolver ();
    check_exit_ok Alcotest.unit "shutdown closes idle" ()
      (B.await shutdown);
    let after_shutdown = Pool.stats pool in
    Alcotest.(check int) "idle removed after close" 0 after_shutdown.Pool.idle;
    Alcotest.(check int) "closed after shutdown" 1 after_shutdown.Pool.closed;
    Alcotest.(check int) "factory closed after shutdown" 1 !(factory.closed)

  let test_pool_shutdown_reports_failure_after_closing_all_idle () =
    B.with_test_clock @@ fun ctx clock rt ->
    let factory = make_pool_factory () in
    let release_attempts = ref 0 in
    let release conn =
      E.sync (fun () -> incr release_attempts)
      |> E.bind (fun () ->
             if !release_attempts = 1 then E.fail `Close_failed
             else pool_close factory conn)
    in
    let pool =
      run_ok rt
        (Pool.create ~name:"test.pool" ~kind:"test" ~max_size:2 ~max_idle:2
           ~acquire:(pool_open factory) ~release ~health_check:pool_health ())
    in
    let hold =
      Pool.with_resource pool (fun _ -> E.delay (Duration.ms 5) E.unit)
    in
    let first = B.fork_run ctx rt hold in
    let second = B.fork_run ctx rt hold in
    wait_until (fun () -> (Pool.stats pool).Pool.active = 2);
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 5);
    check_exit_ok Alcotest.unit "first" () (B.await first);
    check_exit_ok Alcotest.unit "second" () (B.await second);
    wait_until (fun () -> (Pool.stats pool).Pool.idle = 2);
    (match B.run rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) with
    | Exit.Error (Cause.Fail `Close_failed) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected close failure, got %a" (Cause.pp pp_hidden)
          cause
    | Exit.Ok () -> Alcotest.fail "expected close failure");
    Alcotest.(check int) "all idle closes attempted" 2 !release_attempts;
    Alcotest.(check int) "pool accounting closed both" 2
      (Pool.stats pool).Pool.closed

  let test_pool_idle_eviction () =
    B.with_test_clock @@ fun _ctx clock rt ->
    let factory = make_pool_factory () in
    let pool =
      run_ok rt
        (create_test_pool ~max_size:1 ~idle_lifetime:(Duration.ms 2)
           ~idle_check_interval:(Duration.ms 1) factory)
    in
    wait_for_sleepers clock 1;
    ignore (run_ok rt (Pool.with_resource pool pool_use) : int);
    wait_until (fun () -> (Pool.stats pool).Pool.idle = 1);
    B.adjust_clock clock (Duration.ms 1);
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 1);
    wait_until (fun () ->
        let stats = Pool.stats pool in
        stats.Pool.idle = 0 && stats.Pool.closed = 1);
    ignore (run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) : unit)

  let test_pool_idle_eviction_continues_after_close_failure () =
    B.with_test_clock @@ fun _ctx clock rt ->
    let factory = make_pool_factory () in
    let release_attempts = ref 0 in
    let release conn =
      E.sync (fun () -> incr release_attempts)
      |> E.bind (fun () ->
             if !release_attempts = 1 then E.fail `Close_failed
             else pool_close factory conn)
    in
    let pool =
      run_ok rt
        (Pool.create ~name:"test.pool" ~kind:"test" ~max_size:1 ~max_idle:1
           ~idle_lifetime:(Duration.ms 2)
           ~idle_check_interval:(Duration.ms 1)
           ~acquire:(pool_open factory) ~release ~health_check:pool_health ())
    in
    wait_for_sleepers clock 1;
    ignore (run_ok rt (Pool.with_resource pool pool_use) : int);
    wait_until (fun () -> (Pool.stats pool).Pool.idle = 1);
    B.adjust_clock clock (Duration.ms 1);
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 1);
    wait_until (fun () ->
        let stats = Pool.stats pool in
        stats.Pool.idle = 0 && stats.Pool.closed = 1);
    ignore (run_ok rt (Pool.with_resource pool pool_use) : int);
    wait_until (fun () -> (Pool.stats pool).Pool.idle = 1);
    B.adjust_clock clock (Duration.ms 1);
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 1);
    wait_until (fun () ->
        let stats = Pool.stats pool in
        stats.Pool.idle = 0 && stats.Pool.closed = 2);
    Alcotest.(check int) "second close reached release" 2 !release_attempts;
    ignore (run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) : unit)

  let test_pool_expired_idle_cleanup_preserves_capacity_waiters () =
    B.with_test_clock @@ fun ctx clock rt ->
    let factory = make_pool_factory () in
    let pool =
      run_ok rt
        (create_test_pool ~max_size:2 ~max_idle:2
           ~idle_lifetime:(Duration.ms 1)
           ~idle_check_interval:(Duration.hours 1) factory)
    in
    Fun.protect
      ~finally:(fun () ->
        B.adjust_clock clock (Duration.ms 500);
        shutdown_pool_with_test_clock clock rt pool)
      (fun () ->
        wait_for_sleepers clock 1;
        let hold ms =
          Pool.with_resource pool (fun _ -> E.delay (Duration.ms ms) E.unit)
        in
        let warm_a = B.fork_run ctx rt (hold 5) in
        let warm_b = B.fork_run ctx rt (hold 5) in
        wait_until_pool_stats pool (fun stats -> stats.Pool.active = 2);
        wait_for_sleepers clock 3;
        B.adjust_clock clock (Duration.ms 5);
        check_exit_ok Alcotest.unit "warm a" () (B.await warm_a);
        check_exit_ok Alcotest.unit "warm b" () (B.await warm_b);
        wait_until_pool_stats pool (fun stats -> stats.Pool.idle = 2);
        B.adjust_clock clock (Duration.ms 1);
        let holders = List.init 4 (fun _ -> B.fork_run ctx rt (hold 50)) in
        wait_until_pool_stats pool (fun stats ->
            stats.Pool.active = 2 && stats.Pool.waiting >= 1);
        Alcotest.(check int) "max live bounded" 2 !(factory.max_live);
        advance_clock_until_all_resolved clock holders 200;
        List.iter
          (fun p -> check_exit_ok Alcotest.unit "holder done" () (B.await p))
          holders)

  let test_pool_expired_idle_close_failure_releases_admission_permit () =
    B.with_test_clock @@ fun ctx clock rt ->
    let factory = make_pool_factory () in
    let release_calls = ref 0 in
    let release conn =
      E.sync (fun () -> incr release_calls)
      |> E.bind (fun () -> pool_close factory conn)
      |> E.bind (fun () ->
             if !release_calls = 1 then E.fail `Close_failed else E.unit)
    in
    let pool =
      run_ok rt
        (Pool.create ~name:"test.pool" ~kind:"test" ~max_size:1 ~max_idle:1
           ~idle_lifetime:(Duration.ms 1)
           ~idle_check_interval:(Duration.hours 1)
           ~acquire:(pool_open factory) ~release ~health_check:pool_health ())
    in
    ignore (run_ok rt (Pool.with_resource pool pool_use) : int);
    B.adjust_clock clock (Duration.ms 1);
    let close_failure =
      Pool.with_resource pool (fun _ -> E.unit)
      |> E.bind_error (function
           | `Close_failed -> E.unit
           | #pool_test_error as err -> E.fail err)
    in
    run_ok rt close_failure;
    let checkout_after_failure =
      Pool.with_resource pool (fun _ -> E.unit)
      |> E.timeout_as (Duration.ms 20) ~on_timeout:`Timeout
    in
    let checkout_result = B.fork_run ctx rt checkout_after_failure in
    advance_clock_until_resolved clock checkout_result 20;
    (match B.await checkout_result with
    | Exit.Ok () -> ()
    | Exit.Error cause ->
        Alcotest.failf
          "pool permit leaked after expired idle close failure: %a"
          (Cause.pp pp_hidden) cause);
    Alcotest.(check int) "expired close attempted once" 1 !release_calls;
    Alcotest.(check int) "replacement opened" 2 !(factory.opened);
    shutdown_pool_with_test_clock clock rt pool

  let test_pool_release_detects_active_underflow () =
    B.with_runtime @@ fun _ctx rt ->
    let factory = make_pool_factory () in
    let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
    let result =
      B.run rt
        (Pool.with_resource pool (fun _ ->
             E.sync (fun () -> set_pool_active_for_invariant_test pool 0)))
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
          (Cause.pp pp_hidden) cause
    | Exit.Ok () -> Alcotest.fail "expected pool invariant failure");
    set_pool_active_for_invariant_test pool 0

  let test_pool_observability_signals () =
    B.with_observed_runtime @@ fun _ctx rt tracer logger meter ->
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

  let test_pool_lease_invalidation_observability () =
    B.with_observed_runtime @@ fun _ctx rt _tracer logger meter ->
    let factory = make_pool_factory () in
    let pool =
      run_ok rt
        (Pool.create ~name:"obs.pool" ~kind:"sql.client" ~max_size:1
           ~acquire:(pool_open factory) ~release:(pool_close factory)
           ~health_check:pool_health ())
    in
    run_ok rt (Pool.with_lease pool (fun lease -> Pool.Lease.invalidate lease));
    let stats = Pool.stats pool in
    Alcotest.(check int) "invalidated" 1 stats.Pool.invalidated;
    Alcotest.(check int) "closed" 1 stats.Pool.closed;
    Alcotest.(check int) "health not rejected" 0 stats.Pool.health_rejected;
    let metric_names = List.map (fun p -> p.Meter.name) (Meter.dump meter) in
    let has_metric name = List.exists (String.equal name) metric_names in
    Alcotest.(check bool)
      "invalidated metric" true (has_metric "eta.pool.invalidated");
    Alcotest.(check bool) "closed metric" true (has_metric "eta.pool.closed");
    let log_bodies = List.map (fun r -> r.Logger.body) (Logger.dump logger) in
    Alcotest.(check bool) "invalidated log" true
      (List.exists (String.equal "eta.pool.invalidated") log_bodies);
    ignore (run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) : unit)

  let tests =
    [
      ( "Pool",
        [
          Alcotest.test_case "reuses idle LIFO" `Quick
            test_pool_reuses_idle_lifo;
          Alcotest.test_case "body success releases resource" `Quick
            test_pool_with_resource_body_success_releases_resource;
          Alcotest.test_case "body typed failure releases resource" `Quick
            test_pool_with_resource_body_typed_failure_releases_resource;
          Alcotest.test_case "body defect releases resource" `Quick
            test_pool_with_resource_body_defect_releases_resource;
          Alcotest.test_case
            "body interruption releases without invalidation" `Quick
            test_pool_with_resource_body_interruption_releases_without_invalidation;
          Alcotest.test_case
            "lease invalidation closes on release and replaces" `Quick
            test_pool_lease_invalidation_closes_on_release_and_replaces;
          Alcotest.test_case "lease invalidation is idempotent" `Quick
            test_pool_lease_invalidation_is_idempotent;
          Alcotest.test_case
            "lease invalidation preserves typed failure" `Quick
            test_pool_lease_invalidation_preserves_typed_failure;
          Alcotest.test_case "lease invalidation preserves defect" `Quick
            test_pool_lease_invalidation_preserves_defect;
          Alcotest.test_case
            "lease invalidation preserves interruption" `Quick
            test_pool_lease_invalidation_preserves_interruption;
          Alcotest.test_case
            "lease invalidation reports close failure" `Quick
            test_pool_lease_invalidation_reports_close_failure;
          Alcotest.test_case
            "lease invalidation during shutdown closes once" `Quick
            test_pool_lease_invalidation_during_shutdown_closes_once;
          Alcotest.test_case "release defect releases capacity" `Quick
            test_pool_release_defect_releases_capacity;
          Alcotest.test_case "shutdown release defect removes idle" `Quick
            test_pool_shutdown_release_defect_removes_idle_entry;
          Alcotest.test_case "health rejection reopens" `Quick
            test_pool_health_rejection_reopens;
          Alcotest.test_case "acquire failure does not consume capacity"
            `Quick test_pool_acquire_failure_does_not_count_as_active_resource;
          Alcotest.test_case "idle health failure rejects entry" `Quick
            test_pool_idle_health_failure_rejects_entry;
          Alcotest.test_case "idle health defect closes entry" `Quick
            test_pool_idle_health_defect_closes_entry;
          Alcotest.test_case "cancel during health check" `Quick
            test_pool_cancel_during_health_check_closes_reserved;
          Alcotest.test_case "max size under concurrent checkout" `Quick
            test_pool_max_size_respected_under_concurrent_checkout;
          Alcotest.test_case "timeout cleans waiter" `Quick
            test_pool_timeout_cleans_waiter_and_preserves_timeout_cause;
          Alcotest.test_case "shutdown wakes and drains" `Quick
            test_pool_shutdown_wakes_waiters_and_drains;
          Alcotest.test_case
            "shutdown rejects waiter before permit release" `Quick
            test_pool_shutdown_rejects_waiter_before_permit_release;
          Alcotest.test_case "shutdown deadline timeout" `Quick
            test_pool_shutdown_deadline_timeout;
          Alcotest.test_case "shutdown waits for active close" `Quick
            test_pool_shutdown_waits_for_active_close;
          Alcotest.test_case "shutdown deadline waits for idle close" `Quick
            test_pool_shutdown_deadline_waits_for_idle_close;
          Alcotest.test_case "shutdown reports close failure after all idle"
            `Quick test_pool_shutdown_reports_failure_after_closing_all_idle;
          Alcotest.test_case "idle eviction" `Quick test_pool_idle_eviction;
          Alcotest.test_case "idle eviction survives close failure" `Quick
            test_pool_idle_eviction_continues_after_close_failure;
          Alcotest.test_case "expired idle preserves capacity waiters" `Quick
            test_pool_expired_idle_cleanup_preserves_capacity_waiters;
          Alcotest.test_case "expired close failure releases permit" `Quick
            test_pool_expired_idle_close_failure_releases_admission_permit;
          Alcotest.test_case "release detects active underflow" `Quick
            test_pool_release_detects_active_underflow;
          Alcotest.test_case "observability signals" `Quick
            test_pool_observability_signals;
          Alcotest.test_case "lease invalidation observability" `Quick
            test_pool_lease_invalidation_observability;
        ] );
    ]
end
