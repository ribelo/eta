module Lane = Eta_signal_lane

exception Lane_grant_resolution_failed

let hooks =
  Lane.hooks ~note_waiter_enqueued:(fun () -> ())
    ~note_waiter_compaction:(fun () -> ())

let run_effect eff =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let runtime =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ()
  in
  Eta.Runtime.run runtime eff

let expect_effect_ok label eff =
  match run_effect eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error _ -> Alcotest.failf "%s: expected Ok" label

let expect_exit_ok label = function
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error _ -> Alcotest.failf "%s: expected Ok" label

let wait_until label predicate =
  let rec loop attempts =
    if predicate () then ()
    else if attempts = 0 then Alcotest.failf "timed out waiting for %s" label
    else (
      Eio.Fiber.yield ();
      loop (attempts - 1))
  in
  loop 50

let with_hooked_runtime f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let fail_next_resolve = ref false in
  let resolve_failures = ref 0 in
  let module Base =
    (val Eta_eio.runtime ~sw ~clock : Eta.Runtime_contract.RUNTIME)
  in
  let module Hooked_runtime = struct
    type scope = Base.scope
    type cancel_context = Base.cancel_context
    type 'a promise = 'a Base.promise
    type 'a resolver = 'a Base.resolver
    type 'a stream = 'a Base.stream

    let root_scope = Base.root_scope
    let now_ms = Base.now_ms
    let fresh = Base.fresh
    let sleep = Base.sleep
    let protect = Base.protect
    let run_scope = Base.run_scope
    let fail_scope = Base.fail_scope
    let fork = Base.fork
    let fork_daemon = Base.fork_daemon
    let await_cancel = Base.await_cancel
    let yield = Base.yield
    let check = Base.check
    let create_promise = Base.create_promise

    let resolve_promise resolver value =
      if !fail_next_resolve then (
        fail_next_resolve := false;
        incr resolve_failures;
        raise Lane_grant_resolution_failed);
      Base.resolve_promise resolver value

    let await_promise = Base.await_promise
    let create_stream = Base.create_stream
    let stream_add = Base.stream_add
    let stream_take = Base.stream_take
    let stream_take_nonblocking = Base.stream_take_nonblocking
    let with_worker_context = Base.with_worker_context
    let in_worker_context = Base.in_worker_context
    let cancellation_reason = Base.cancellation_reason
    let multiple_exceptions = Base.multiple_exceptions
    let cancel_sub = Base.cancel_sub
    let cancel = Base.cancel
    let local_get = Base.local_get
    let local_with_binding = Base.local_with_binding
    let current_fiber_id = Base.current_fiber_id
    let with_fiber_identity = Base.with_fiber_identity
  end in
  let runtime =
    Eta.Runtime.create_with_runtime
      (module Hooked_runtime : Eta.Runtime_contract.RUNTIME)
      ()
  in
  f sw runtime ~fail_next_resolve ~resolve_failures

let lane_effect ?(after_acquired = fun () -> Eta.Effect.unit) lane f =
  Lane.with_sync ~leaf_name:"eta_signal_lane.test"
    ~depth_local:(Eta.Runtime_contract.create_local ())
    ~ensure_context:(fun () -> ()) ~hooks ~after_acquired lane f

let test_cancelled_compaction_policy () =
  Alcotest.(check bool) "empty queue" false
    (Lane.should_compact_cancelled ~retained_cancelled:1 ~queue_length:0);
  Alcotest.(check bool) "no retained cancellation" false
    (Lane.should_compact_cancelled ~retained_cancelled:0 ~queue_length:4);
  Alcotest.(check bool) "below half" false
    (Lane.should_compact_cancelled ~retained_cancelled:1 ~queue_length:4);
  Alcotest.(check bool) "half compacted" true
    (Lane.should_compact_cancelled ~retained_cancelled:2 ~queue_length:4);
  Alcotest.(check bool) "odd half rounded up" true
    (Lane.should_compact_cancelled ~retained_cancelled:2 ~queue_length:3)

let test_reentry_policy () =
  Alcotest.(check bool) "depth permits reentry" true
    (Lane.can_reenter ~lane_depth:1 ~owner_fiber_id:None ~current_fiber_id:10);
  Alcotest.(check bool) "same owner permits reentry" true
    (Lane.can_reenter ~lane_depth:0 ~owner_fiber_id:(Some 10)
       ~current_fiber_id:10);
  Alcotest.(check bool) "different owner waits" false
    (Lane.can_reenter ~lane_depth:0 ~owner_fiber_id:(Some 11)
       ~current_fiber_id:10);
  Alcotest.(check bool) "unowned lane enters normally" false
    (Lane.can_reenter ~lane_depth:0 ~owner_fiber_id:None ~current_fiber_id:10)

let test_access_token_guards_leave () =
  let lane = Lane.create () in
  let eff =
    Eta.Effect.Expert.make ~leaf_name:"eta_signal_lane.test" @@ fun context ->
    try
      let contract = Eta.Effect.Expert.contract context in
      let first = Lane.enter ~hooks contract lane in
      Lane.leave lane first;
      Alcotest.check_raises "stale token"
        (Invalid_argument
           "Eta_signal lane invariant failed: lane access token is stale")
        (fun () -> Lane.leave lane first);
      let second = Lane.enter ~hooks contract lane in
      Alcotest.check_raises "inactive token"
        (Invalid_argument
           "Eta_signal lane invariant failed: lane access token is not active")
        (fun () -> Lane.leave lane first);
      Lane.leave lane second;
      Eta.Exit.Ok ()
    with exn -> Eta.Effect.Expert.exit_of_exn context exn
  in
  expect_effect_ok "lane access token" eff

let test_granted_waiter_survives_resolver_failure () =
  with_hooked_runtime @@ fun sw runtime ~fail_next_resolve
      ~resolve_failures ->
  let lane = Lane.create () in
  let acquired, acquired_resolver = Eio.Promise.create () in
  let release, release_resolver = Eio.Promise.create () in
  let hook_ran = ref false in
  let after_acquired () =
    Eta.Effect.sync (fun () ->
        if not !hook_ran then (
          hook_ran := true;
          Eio.Promise.resolve acquired_resolver ();
          Eio.Promise.await release))
  in
  let first =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eta.Runtime.run runtime
          (lane_effect ~after_acquired lane (fun _access -> ())))
  in
  Eio.Promise.await acquired;
  let queued =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eta.Runtime.run runtime (lane_effect lane (fun _access -> ())))
  in
  for _ = 1 to 5 do
    Eio.Fiber.yield ()
  done;
  Alcotest.(check bool) "queued waiter waits behind lane" false
    (Eio.Promise.is_resolved queued);
  fail_next_resolve := true;
  Eio.Promise.resolve release_resolver ();
  wait_until "first lane effect" (fun () -> Eio.Promise.is_resolved first);
  ignore (expect_exit_ok "first lane effect" (Eio.Promise.await_exn first));
  wait_until "queued lane effect" (fun () -> Eio.Promise.is_resolved queued);
  ignore (expect_exit_ok "queued lane effect" (Eio.Promise.await_exn queued));
  Alcotest.(check int) "grant resolver failed once" 1 !resolve_failures;
  ignore
    (expect_exit_ok "future lane effect"
       (Eta.Runtime.run runtime (lane_effect lane (fun _access -> ()))))

let test_acquisitions_stay_on_owner_domain () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let runtime =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ()
  in
  let lane = Lane.create () in
  let owner = Domain.self () in
  let acquired_domains = ref [] in
  let started, started_resolver = Eio.Promise.create () in
  let release, release_resolver = Eio.Promise.create () in
  let block_once = ref true in
  let after_acquired () =
    Eta.Effect.sync (fun () ->
        acquired_domains := Domain.self () :: !acquired_domains;
        if !block_once then (
          block_once := false;
          Eio.Promise.resolve started_resolver ();
          Eio.Promise.await release))
  in
  let first =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eta.Runtime.run runtime
          (lane_effect ~after_acquired lane (fun _access -> ())))
  in
  Eio.Promise.await started;
  let queued =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eta.Runtime.run runtime
          (lane_effect ~after_acquired lane (fun _access -> ())))
  in
  for _ = 1 to 5 do
    Eio.Fiber.yield ()
  done;
  Alcotest.(check bool) "queued waiter waits behind lane" false
    (Eio.Promise.is_resolved queued);
  Eio.Promise.resolve release_resolver ();
  ignore (expect_exit_ok "first lane effect" (Eio.Promise.await_exn first));
  ignore (expect_exit_ok "queued lane effect" (Eio.Promise.await_exn queued));
  ignore
    (expect_exit_ok "immediate lane effect"
       (Eta.Runtime.run runtime
          (lane_effect ~after_acquired lane (fun _access -> ()))));
  Alcotest.(check bool) "lane acquisitions stayed on owner domain" true
    (List.for_all (fun domain -> domain = owner) !acquired_domains);
  Alcotest.(check int) "observed lane acquisitions" 3
    (List.length !acquired_domains)

let test_generated_waiter_cancellation_never_double_grants () =
  List.iter
    (fun seed ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let runtime =
        Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ()
      in
      let lane = Lane.create () in
      let waiter_count = 12 in
      let random = Random.State.make [| seed; waiter_count; 211 |] in
      let cancelled =
        Array.init waiter_count (fun _ -> Random.State.bool random)
      in
      let acquired = Array.make waiter_count 0 in
      let contexts = Array.make waiter_count None in
      let started, started_resolver = Eio.Promise.create () in
      let release, release_resolver = Eio.Promise.create () in
      let holder =
        Eio.Fiber.fork_promise ~sw (fun () ->
            Eta.Runtime.run runtime
              (lane_effect
                 ~after_acquired:(fun () ->
                   Eta.Effect.sync (fun () ->
                       Eio.Promise.resolve started_resolver ();
                       Eio.Promise.await release))
                 lane (fun _access -> ())))
      in
      Eio.Promise.await started;
      let ready =
        Array.init waiter_count (fun _ -> Eio.Promise.create ())
      in
      let waiters =
        Array.init waiter_count (fun index ->
            let _ready_promise, ready_resolver = ready.(index) in
            Eio.Fiber.fork_promise ~sw (fun () ->
                Eio.Cancel.sub @@ fun context ->
                contexts.(index) <- Some context;
                Eio.Promise.resolve ready_resolver ();
                Eta.Runtime.run runtime
                  (lane_effect lane (fun _access ->
                       acquired.(index) <- acquired.(index) + 1))))
      in
      Array.iter (fun (promise, _resolver) -> Eio.Promise.await promise) ready;
      for _ = 1 to 5 do
        Eio.Fiber.yield ()
      done;
      Array.iteri
        (fun index should_cancel ->
          if should_cancel then
            Option.iter (fun context -> Eio.Cancel.cancel context Exit)
              contexts.(index))
        cancelled;
      Eio.Promise.resolve release_resolver ();
      ignore (expect_exit_ok "generated holder" (Eio.Promise.await_exn holder));
      Array.iteri
        (fun index waiter ->
          if cancelled.(index) then
            (match Eio.Promise.await_exn waiter with
            | exception Eio.Cancel.Cancelled _ -> ()
            | Eta.Exit.Ok () ->
                Alcotest.failf "seed %d waiter %d acquired after cancellation"
                  seed index
            | Eta.Exit.Error _ ->
                Alcotest.failf "seed %d waiter %d returned an Eta error" seed
                  index)
          else
            ignore
              (expect_exit_ok
                 (Format.asprintf "seed %d waiter %d" seed index)
                 (Eio.Promise.await_exn waiter)))
        waiters;
      Array.iteri
        (fun index count ->
          Alcotest.(check int)
            (Format.asprintf "seed %d waiter %d grant count" seed index)
            (if cancelled.(index) then 0 else 1)
            count)
        acquired;
      ignore
        (expect_exit_ok "lane remains usable after generated cancellation"
           (Eta.Runtime.run runtime (lane_effect lane (fun _access -> ())))))
    [ 5; 13; 29; 47; 83; 131; 197; 251 ]

let () =
  Alcotest.run "eta_signal_lane"
    [
      ( "lane",
        [
          Alcotest.test_case "cancelled compaction policy" `Quick
            test_cancelled_compaction_policy;
          Alcotest.test_case "reentry policy" `Quick test_reentry_policy;
          Alcotest.test_case "access token guards leave" `Quick
            test_access_token_guards_leave;
          Alcotest.test_case "granted waiter survives resolver failure" `Quick
            test_granted_waiter_survives_resolver_failure;
          Alcotest.test_case "acquisitions stay on owner domain" `Quick
            test_acquisitions_stay_on_owner_domain;
          Alcotest.test_case "generated waiter cancellation never double grants"
            `Quick test_generated_waiter_cancellation_never_double_grants;
        ] );
    ]
