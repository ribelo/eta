open Eta

[@@@alert "-unsafe_multidomain"]

exception Promise_blocked
exception Await_cancelled
exception Reentered_locked_queue

module Hooked_runtime = struct
  type scope = unit
  type cancel_context = unit
  type 'a promise = 'a option ref
  type 'a resolver = 'a option ref
  type 'a stream = 'a Stdlib.Queue.t

  let resolve_hook = ref (fun () -> ())
  let await_hook = ref (fun () -> ())
  let cancel_after_resolved_await = ref false
  let fresh_counter = ref 0
  let root_scope = ()
  let now_ms () = 0
  let fresh () = incr fresh_counter; !fresh_counter
  let sleep _ = ()
  let protect f = f ()
  let run_scope ?name:_ f = f ()
  let fail_scope ?bt:_ () exn = raise exn
  let fork () f = f ()
  let fork_daemon () f = ignore (f () : [ `Stop_daemon ])
  let await_cancel () = raise Promise_blocked
  let yield () = ()
  let check () = ()

  let create_promise () =
    let cell = ref None in
    (cell, cell)

  let resolve_promise resolver value =
    !resolve_hook ();
    match !resolver with
    | Some _ -> invalid_arg "Hooked_runtime.resolve_promise: already resolved"
    | None -> resolver := Some value

  let await_promise promise =
    if Option.is_none !promise then !await_hook ();
    match !promise with
    | Some value ->
        if !cancel_after_resolved_await then (
          cancel_after_resolved_await := false;
          raise Await_cancelled);
        value
    | None -> raise Promise_blocked

  let create_stream _capacity = Stdlib.Queue.create ()
  let stream_add stream value = Stdlib.Queue.add value stream

  let stream_take stream =
    if Stdlib.Queue.is_empty stream then
      failwith "Hooked_runtime.stream_take: empty"
    else Stdlib.Queue.take stream

  let stream_take_nonblocking stream =
    if Stdlib.Queue.is_empty stream then None else Some (Stdlib.Queue.take stream)

  let with_worker_context f = f ()
  let in_worker_context () = false
  let cancellation_reason = function
    | Await_cancelled -> Some Await_cancelled
    | _ -> None
  let multiple_exceptions _ = None
  let cancel_sub f = f ()
  let cancel () exn = raise exn
  let current_fiber_id () = 0
  let with_fiber_identity f = f ()
  let local_get _ = None
  let local_with_binding _ _ f = f ()
end

module Test_runtime = Runtime.Make (Hooked_runtime)

let pp_hidden ppf _ = Format.pp_print_string ppf "<err>"

let run_ok rt eff =
  match Test_runtime.run rt eff with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause

let expect_exit_ok label = function
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Alcotest.failf "%s: expected Ok, got %a" label
        (Cause.pp pp_hidden) cause

let expect_blocked = function
  | Exit.Error (Cause.Die { exn = Promise_blocked; _ }) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected blocked promise defect, got %a"
        (Cause.pp pp_hidden) cause
  | Exit.Ok _ -> Alcotest.fail "expected blocked promise defect"

let with_reentry_alarm f =
  let previous =
    Sys.signal Sys.sigalrm
      (Sys.Signal_handle (fun _ -> raise Reentered_locked_queue))
  in
  ignore (Unix.alarm 1 : int);
  Fun.protect
    ~finally:(fun () ->
      ignore (Unix.alarm 0 : int);
      ignore (Sys.signal Sys.sigalrm previous))
    f

let run_in_domain f =
  let domain =
    (Domain.spawn [@alert "-do_not_spawn_domains"] [@alert "-unsafe_multidomain"])
      f
  in
  Domain.join domain

let test_queue_allows_cross_domain_sync_use () =
  let queue = Queue.unbounded () in
  match
    run_in_domain @@ fun () ->
    try
      ignore (Queue.stats queue : Queue.stats);
      Queue.close queue;
      Ok ()
    with
    | Invalid_argument message -> Error message
    | exn ->
        Alcotest.failf "expected cross-domain queue use to succeed, got %s"
          (Printexc.to_string exn)
  with
  | Ok () ->
      Alcotest.(check bool)
        "closed from foreign domain" true (Queue.stats queue).closed
  | Error message ->
      Alcotest.failf "cross-domain queue use was rejected: %s" message

let test_queue_take_up_to_zero_allows_cross_domain_use () =
  let queue = Queue.unbounded () in
  match
    run_in_domain @@ fun () ->
    let rt = Test_runtime.create () in
    match Test_runtime.run rt (Queue.take_up_to queue ~max:0) with
    | Exit.Ok values -> Ok values
    | Exit.Error cause ->
        Alcotest.failf "expected cross-domain zero drain to succeed, got %a"
          (Cause.pp pp_hidden) cause
  with
  | Ok values -> Alcotest.(check (list int)) "empty zero drain" [] values
  | Error message ->
      Alcotest.failf "cross-domain zero drain was rejected: %s" message

let yield_until label predicate =
  let rec loop = function
    | 0 -> Alcotest.failf "timed out waiting for %s" label
    | attempts ->
        if predicate () then ()
        else (
          Eio.Fiber.yield ();
          loop (attempts - 1))
  in
  loop 20

let test_queue_foreign_try_offer_wakes_owner_receiver () =
  Test_eta_support.with_test_clock @@ fun sw _clock rt ->
  let owner = Domain.self () in
  let queue = Queue.unbounded () in
  let started, started_resolver = Eio.Promise.create () in
  let receiver =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Runtime.run rt
          (Effect.sync (fun () -> Eio.Promise.resolve started_resolver ())
          |> Effect.bind (fun () -> Queue.take queue)
          |> Effect.map (fun value -> (value, Domain.self ()))))
  in
  Eio.Promise.await started;
  yield_until "owner receiver waiter" (fun () ->
      (Queue.stats queue).Queue.waiting_receivers = 1);
  let foreign_offer =
    run_in_domain @@ fun () ->
    let foreign_rt = Test_runtime.create () in
    Test_runtime.run foreign_rt (Queue.try_offer queue 42)
  in
  (match foreign_offer with
  | Exit.Ok `Sent -> ()
  | Exit.Ok _ -> Alcotest.fail "expected foreign offer to be sent"
  | Exit.Error cause ->
      Alcotest.failf "foreign offer failed: %a" (Cause.pp pp_hidden) cause);
  let value, resumed_domain =
    expect_exit_ok "foreign offer receiver wakeup" (Eio.Promise.await_exn receiver)
  in
  Alcotest.(check int) "received foreign value" 42 value;
  Alcotest.(check bool)
    "receiver continuation resumed on owner domain" true
    (resumed_domain = owner)

let test_queue_foreign_take_wakes_owner_sender () =
  Test_eta_support.with_test_clock @@ fun sw _clock rt ->
  let owner = Domain.self () in
  let queue = Queue.bounded ~capacity:1 () in
  Test_eta_support.run_ok rt (Queue.send queue 1);
  let started, started_resolver = Eio.Promise.create () in
  let sender =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Runtime.run rt
          (Effect.sync (fun () -> Eio.Promise.resolve started_resolver ())
          |> Effect.bind (fun () -> Queue.offer queue 2)
          |> Effect.map (fun admitted -> (admitted, Domain.self ()))))
  in
  Eio.Promise.await started;
  yield_until "owner sender waiter" (fun () ->
      (Queue.stats queue).Queue.waiting_senders = 1);
  let foreign_take =
    run_in_domain @@ fun () ->
    let foreign_rt = Test_runtime.create () in
    Test_runtime.run foreign_rt (Queue.take queue)
  in
  (match foreign_take with
  | Exit.Ok value -> Alcotest.(check int) "foreign took first value" 1 value
  | Exit.Error cause ->
      Alcotest.failf "foreign take failed: %a" (Cause.pp pp_hidden) cause);
  let admitted, resumed_domain =
    expect_exit_ok "foreign take sender wakeup" (Eio.Promise.await_exn sender)
  in
  Alcotest.(check bool) "sender admitted" true admitted;
  Alcotest.(check bool)
    "sender continuation resumed on owner domain" true
    (resumed_domain = owner);
  Alcotest.(check int) "admitted value remains" 2
    (Test_eta_support.run_ok rt (Queue.take queue))

let test_queue_foreign_shutdown_wakes_owner_receiver () =
  Test_eta_support.with_test_clock @@ fun sw _clock rt ->
  let queue = Queue.unbounded () in
  let started, started_resolver = Eio.Promise.create () in
  let receiver =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Runtime.run rt
          (Effect.sync (fun () -> Eio.Promise.resolve started_resolver ())
          |> Effect.bind (fun () -> Queue.take queue)))
  in
  Eio.Promise.await started;
  yield_until "owner receiver waiter" (fun () ->
      (Queue.stats queue).Queue.waiting_receivers = 1);
  run_in_domain (fun () -> Queue.shutdown queue);
  (match Eio.Promise.await_exn receiver with
  | Exit.Error (Cause.Fail `Closed) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected closed receiver, got %a"
        (Cause.pp pp_hidden) cause
  | Exit.Ok value ->
      Alcotest.failf "expected closed receiver, got value %d" value);
  Alcotest.(check bool) "shutdown committed" true (Queue.is_shutdown queue)

let test_queue_backpressure_sender_wakeup_stays_on_owner_domain () =
  Test_eta_support.with_test_clock @@ fun sw _clock rt ->
  let owner = Domain.self () in
  let queue = Queue.bounded ~capacity:1 () in
  Alcotest.(check unit)
    "initial send" ()
    (Test_eta_support.run_ok rt (Queue.send queue 1));
  let started, started_resolver = Eio.Promise.create () in
  let sender =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Runtime.run rt
          (Effect.sync (fun () -> Eio.Promise.resolve started_resolver ())
          |> Effect.bind (fun () -> Queue.offer queue 2)
          |> Effect.map (fun admitted -> (admitted, Domain.self ()))))
  in
  Eio.Promise.await started;
  yield_until "backpressure sender waiter" (fun () ->
      (Queue.stats queue).Queue.waiting_senders = 1);
  Alcotest.(check int) "first value" 1
    (Test_eta_support.run_ok rt (Queue.take queue));
  let admitted, resumed_domain =
    expect_exit_ok "backpressure sender" (Eio.Promise.await_exn sender)
  in
  Alcotest.(check bool) "sender admitted" true admitted;
  Alcotest.(check bool)
    "sender continuation resumed on owner domain" true
    (resumed_domain = owner);
  Alcotest.(check int) "admitted value" 2
    (Test_eta_support.run_ok rt (Queue.take queue))

let test_queue_receiver_wakeup_stays_on_owner_domain () =
  Test_eta_support.with_test_clock @@ fun sw _clock rt ->
  let owner = Domain.self () in
  let queue = Queue.unbounded () in
  let started, started_resolver = Eio.Promise.create () in
  let receiver =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Runtime.run rt
          (Effect.sync (fun () -> Eio.Promise.resolve started_resolver ())
          |> Effect.bind (fun () -> Queue.take queue)
          |> Effect.map (fun value -> (value, Domain.self ()))))
  in
  Eio.Promise.await started;
  yield_until "receiver waiter" (fun () ->
      (Queue.stats queue).Queue.waiting_receivers = 1);
  Test_eta_support.run_ok rt (Queue.send queue 7);
  let value, resumed_domain =
    expect_exit_ok "receiver wakeup" (Eio.Promise.await_exn receiver)
  in
  Alcotest.(check int) "received value" 7 value;
  Alcotest.(check bool)
    "receiver continuation resumed on owner domain" true
    (resumed_domain = owner)

let test_queue_resolves_sender_outside_lock () =
  let rt = Test_runtime.create () in
  let queue = Queue.bounded ~capacity:1 () in
  Alcotest.(check bool) "first offer" true (run_ok rt (Queue.offer queue 1));
  expect_blocked (Test_runtime.run rt (Queue.offer queue 2));
  Alcotest.(check int) "sender waits" 1 (Queue.stats queue).Queue.waiting_senders;
  let hook_ran = ref false in
  Hooked_runtime.resolve_hook :=
    (fun () ->
      hook_ran := true;
      ignore (Queue.stats queue : Queue.stats));
  let first =
    Fun.protect
      ~finally:(fun () -> Hooked_runtime.resolve_hook := (fun () -> ()))
      (fun () ->
        try with_reentry_alarm (fun () -> run_ok rt (Queue.take queue))
        with Reentered_locked_queue ->
          Alcotest.fail "queue resolver re-entered while the queue lock was held")
  in
  Alcotest.(check int) "first recv" 1 first;
  Alcotest.(check bool) "resolver hook ran" true !hook_ran;
  Alcotest.(check int) "admitted blocked sender" 2
    (run_ok rt (Queue.take queue))

let reset_hooked_runtime () =
  Hooked_runtime.resolve_hook := (fun () -> ());
  Hooked_runtime.await_hook := (fun () -> ());
  Hooked_runtime.cancel_after_resolved_await := false

let test_queue_receiver_wakeup_reserves_value_for_waiter () =
  let rt = Test_runtime.create () in
  let queue = Queue.unbounded () in
  let late_recv = ref None in
  Fun.protect
    ~finally:reset_hooked_runtime
    (fun () ->
      Hooked_runtime.await_hook :=
        (fun () ->
          Hooked_runtime.await_hook := (fun () -> ());
          Hooked_runtime.resolve_hook :=
            (fun () ->
              Hooked_runtime.resolve_hook := (fun () -> ());
              late_recv := Some (run_ok rt (Queue.poll queue)));
          run_ok rt (Queue.send queue 7));
      Alcotest.(check int)
        "parked receiver gets sent value" 7
        (run_ok rt (Queue.take queue)));
  match !late_recv with
  | Some `Empty -> ()
  | Some (`Item value) ->
      Alcotest.failf "late receiver stole reserved value %d" value
  | Some `Closed -> Alcotest.fail "late receiver saw closed queue"
  | Some (`Closed_with_error _) ->
      Alcotest.fail "late receiver saw error-closed queue"
  | None -> Alcotest.fail "late receiver did not run"

let test_queue_recv_result_survives_sender_wakeup_failure () =
  let rt = Test_runtime.create () in
  let queue = Queue.bounded ~capacity:1 () in
  Alcotest.(check bool) "initial offer" true (run_ok rt (Queue.offer queue 1));
  expect_blocked (Test_runtime.run rt (Queue.offer queue 2));
  let resolve_attempts = ref 0 in
  Fun.protect
    ~finally:reset_hooked_runtime
    (fun () ->
      Hooked_runtime.resolve_hook :=
        (fun () ->
          incr resolve_attempts;
          if !resolve_attempts = 1 then raise Await_cancelled);
      Alcotest.(check int) "recv returns committed item" 1
        (run_ok rt (Queue.take queue)));
  Alcotest.(check int) "wakeup retried" 2 !resolve_attempts;
  Alcotest.(check int) "admitted sender value remains" 2
    (run_ok rt (Queue.take queue))

let test_queue_backpressure_admission_wins_racing_cancellation () =
  let rt = Test_runtime.create () in
  let queue = Queue.bounded ~capacity:1 () in
  Alcotest.(check bool) "initial offer" true (run_ok rt (Queue.offer queue 1));
  let await_hook_ran = ref false in
  Fun.protect
    ~finally:reset_hooked_runtime
    (fun () ->
      Hooked_runtime.await_hook :=
        (fun () ->
          await_hook_ran := true;
          Hooked_runtime.await_hook := (fun () -> ());
          Alcotest.(check int)
            "first value opened capacity" 1
            (run_ok rt (Queue.take queue));
          Hooked_runtime.cancel_after_resolved_await := true);
      match Test_runtime.run rt (Queue.offer queue 2) with
      | Exit.Ok true -> ()
      | Exit.Ok false -> Alcotest.fail "admitted backpressure offer returned false"
      | Exit.Error cause ->
          Alcotest.failf "expected admitted offer, got %a"
            (Cause.pp pp_hidden) cause
      | exception Await_cancelled ->
          Alcotest.fail
            "cancellation after queue admission made the sender look uncommitted");
  Alcotest.(check bool) "await hook ran" true !await_hook_ran;
  Alcotest.(check int) "admitted value remains exactly once" 2
    (run_ok rt (Queue.take queue));
  let stats = Queue.stats queue in
  Alcotest.(check int) "no waiting sender remains" 0 stats.Queue.waiting_senders;
  Alcotest.(check int) "admitted sender not counted cancelled" 0
    stats.Queue.cancelled_senders

let check_queue_drain_interrupted_wakeup_still_admits_sender drain =
  let rt = Test_runtime.create () in
  let queue = Queue.bounded ~capacity:1 () in
  Alcotest.(check bool) "initial offer" true (run_ok rt (Queue.offer queue 1));
  let drain_ran = ref false in
  let interrupted_wakeup = ref false in
  Fun.protect
    ~finally:reset_hooked_runtime
    (fun () ->
      Hooked_runtime.await_hook :=
        (fun () ->
          Hooked_runtime.await_hook := (fun () -> ());
          Hooked_runtime.resolve_hook :=
            (fun () ->
              if not !interrupted_wakeup then (
                interrupted_wakeup := true;
                Hooked_runtime.resolve_hook := (fun () -> ());
                raise Await_cancelled));
          drain_ran := true;
          match Test_runtime.run rt (drain queue) with
          | Exit.Ok [ 1 ] -> ()
          | exception Await_cancelled -> ()
          | Exit.Ok values ->
              Alcotest.failf "unexpected drained values: [%s]"
                (String.concat "; " (List.map string_of_int values))
          | Exit.Error cause ->
              Alcotest.failf "unexpected drain failure: %a"
                (Cause.pp pp_hidden) cause);
      match Test_runtime.run rt (Queue.offer queue 2) with
      | Exit.Ok true -> ()
      | Exit.Ok false -> Alcotest.fail "admitted backpressure offer returned false"
      | Exit.Error cause ->
          Alcotest.failf "expected admitted offer, got %a"
            (Cause.pp pp_hidden) cause
      | exception Await_cancelled ->
          Alcotest.fail
            "consumer interruption stranded an admitted backpressure sender");
  Alcotest.(check bool) "drain ran" true !drain_ran;
  Alcotest.(check bool) "wakeup was interrupted" true !interrupted_wakeup;
  Alcotest.(check int) "admitted value remains" 2
    (run_ok rt (Queue.take queue));
  let stats = Queue.stats queue in
  Alcotest.(check int) "no waiting sender remains" 0 stats.Queue.waiting_senders;
  Alcotest.(check int) "admitted sender not counted cancelled" 0
    stats.Queue.cancelled_senders

let test_queue_take_batch_interrupted_wakeup_still_admits_sender () =
  check_queue_drain_interrupted_wakeup_still_admits_sender (fun queue ->
      Queue.take_up_to queue ~max:1)

let test_queue_take_all_interrupted_wakeup_still_admits_sender () =
  check_queue_drain_interrupted_wakeup_still_admits_sender Queue.take_all

let check_queue_receive_interrupted_wakeup_still_admits_sender receive =
  let rt = Test_runtime.create () in
  let queue = Queue.bounded ~capacity:1 () in
  Alcotest.(check bool) "initial offer" true (run_ok rt (Queue.offer queue 1));
  let receive_ran = ref false in
  let interrupted_wakeup = ref false in
  Fun.protect
    ~finally:reset_hooked_runtime
    (fun () ->
      Hooked_runtime.await_hook :=
        (fun () ->
          Hooked_runtime.await_hook := (fun () -> ());
          Hooked_runtime.resolve_hook :=
            (fun () ->
              if not !interrupted_wakeup then (
                interrupted_wakeup := true;
                Hooked_runtime.resolve_hook := (fun () -> ());
                raise Await_cancelled));
          receive_ran := true;
          match Test_runtime.run rt (receive queue) with
          | Exit.Ok () -> ()
          | Exit.Error _ when !interrupted_wakeup -> ()
          | Exit.Error cause ->
              Alcotest.failf "unexpected receive failure: %a"
                (Cause.pp pp_hidden) cause
          | exception Await_cancelled -> ());
      match Test_runtime.run rt (Queue.offer queue 2) with
      | Exit.Ok true -> ()
      | Exit.Ok false -> Alcotest.fail "admitted backpressure offer returned false"
      | Exit.Error cause ->
          Alcotest.failf "expected admitted offer, got %a"
            (Cause.pp pp_hidden) cause
      | exception Await_cancelled ->
          Alcotest.fail
            "consumer interruption stranded an admitted backpressure sender");
  Alcotest.(check bool) "receive ran" true !receive_ran;
  Alcotest.(check bool) "wakeup was interrupted" true !interrupted_wakeup;
  Alcotest.(check int) "admitted value remains" 2
    (run_ok rt (Queue.take queue));
  let stats = Queue.stats queue in
  Alcotest.(check int) "no waiting sender remains" 0 stats.Queue.waiting_senders;
  Alcotest.(check int) "admitted sender not counted cancelled" 0
    stats.Queue.cancelled_senders

let test_queue_try_recv_interrupted_wakeup_still_admits_sender () =
  check_queue_receive_interrupted_wakeup_still_admits_sender (fun queue ->
      Queue.poll queue
      |> Effect.map (function
           | `Item 1 -> ()
           | `Item value ->
               Alcotest.failf "unexpected try_recv item: %d" value
           | `Empty -> Alcotest.fail "try_recv unexpectedly returned empty"
           | `Closed -> Alcotest.fail "try_recv unexpectedly reported clean close"
           | `Closed_with_error _ ->
               Alcotest.fail "try_recv unexpectedly reported error close"))

let test_queue_recv_interrupted_wakeup_still_admits_sender () =
  check_queue_receive_interrupted_wakeup_still_admits_sender (fun queue ->
      Queue.take queue
      |> Effect.map (fun value ->
             Alcotest.(check int) "received buffered value" 1 value))

let test_queue_close_interrupted_wakeup_still_wakes_sender () =
  let rt = Test_runtime.create () in
  let queue = Queue.bounded ~capacity:1 () in
  Alcotest.(check bool) "initial offer" true (run_ok rt (Queue.offer queue 1));
  let close_ran = ref false in
  let interrupted_wakeup = ref false in
  Fun.protect
    ~finally:reset_hooked_runtime
    (fun () ->
      Hooked_runtime.await_hook :=
        (fun () ->
          Hooked_runtime.await_hook := (fun () -> ());
          Hooked_runtime.resolve_hook :=
            (fun () ->
              if not !interrupted_wakeup then (
                interrupted_wakeup := true;
                Hooked_runtime.resolve_hook := (fun () -> ());
                raise Await_cancelled));
          close_ran := true;
          try Queue.close_with_error queue `Boom with Await_cancelled -> ());
      match Test_runtime.run rt (Queue.offer queue 2) with
      | Exit.Error (Cause.Fail (`Closed_with_error `Boom)) -> ()
      | Exit.Error cause ->
          Alcotest.failf "expected close error, got %a"
            (Cause.pp pp_hidden) cause
      | Exit.Ok admitted ->
          Alcotest.failf "closed backpressure offer returned %b" admitted
      | exception Await_cancelled ->
          Alcotest.fail "close interruption stranded a waiting sender");
  Alcotest.(check bool) "close ran" true !close_ran;
  Alcotest.(check bool) "wakeup was interrupted" true !interrupted_wakeup;
  let stats = Queue.stats queue in
  Alcotest.(check bool) "queue is closed" true stats.Queue.closed;
  Alcotest.(check int) "no waiting sender remains" 0 stats.Queue.waiting_senders;
  Alcotest.(check int) "blocked value was not admitted" 1 stats.Queue.depth

let setup_full_backpressure_queue_with_two_senders rt =
  let queue = Queue.bounded ~capacity:1 () in
  Alcotest.(check bool) "initial offer" true (run_ok rt (Queue.offer queue 1));
  expect_blocked (Test_runtime.run rt (Queue.offer queue 2));
  expect_blocked (Test_runtime.run rt (Queue.offer queue 3));
  let stats = Queue.stats queue in
  Alcotest.(check int) "initial depth" 1 stats.Queue.depth;
  Alcotest.(check int) "two senders waiting" 2 stats.Queue.waiting_senders;
  queue

let with_first_resolver_failure f =
  let resolve_attempts = ref 0 in
  Fun.protect
    ~finally:reset_hooked_runtime
    (fun () ->
      Hooked_runtime.resolve_hook :=
        (fun () ->
          incr resolve_attempts;
          if !resolve_attempts = 1 then raise Await_cancelled);
      f resolve_attempts)

let check_admitted_sender_woken_after_resolver_failure operation =
  let rt = Test_runtime.create () in
  let queue = setup_full_backpressure_queue_with_two_senders rt in
  with_first_resolver_failure @@ fun resolve_attempts ->
  (match Test_runtime.run rt (operation queue) with
  | Exit.Ok () -> ()
  | Exit.Error cause ->
      Alcotest.failf "unexpected operation failure: %a"
        (Cause.pp pp_hidden) cause
  | exception Await_cancelled -> ());
  Alcotest.(check int) "resolver retried" 2 !resolve_attempts;
  let stats = Queue.stats queue in
  Alcotest.(check int) "admitted value buffered" 1 stats.Queue.depth;
  Alcotest.(check int) "second sender still honestly waiting" 1
    stats.Queue.waiting_senders;
  Alcotest.(check int) "admitted value" 2 (run_ok rt (Queue.take queue));
  Alcotest.(check int) "second sender resolved after capacity opens" 3
    !resolve_attempts;
  let stats = Queue.stats queue in
  Alcotest.(check int) "no stranded sender" 0 stats.Queue.waiting_senders;
  Alcotest.(check int) "second waiting value" 3 (run_ok rt (Queue.take queue))

let test_queue_try_recv_admitted_sender_is_woken_even_if_resolver_raises () =
  check_admitted_sender_woken_after_resolver_failure (fun queue ->
      Queue.poll queue
      |> Effect.map (function
           | `Item 1 -> ()
           | `Item value ->
               Alcotest.failf "unexpected try_recv item: %d" value
           | `Empty -> Alcotest.fail "try_recv unexpectedly returned empty"
           | `Closed -> Alcotest.fail "try_recv unexpectedly reported clean close"
           | `Closed_with_error _ ->
               Alcotest.fail "try_recv unexpectedly reported error close"))

let test_queue_recv_admitted_sender_is_woken_even_if_resolver_raises () =
  check_admitted_sender_woken_after_resolver_failure (fun queue ->
      Queue.take queue
      |> Effect.map (fun value ->
             Alcotest.(check int) "received buffered value" 1 value))

let test_queue_take_all_admitted_sender_is_woken_even_if_resolver_raises () =
  check_admitted_sender_woken_after_resolver_failure (fun queue ->
      Queue.take_all queue
      |> Effect.map (fun values ->
             Alcotest.(check (list int)) "drained values" [ 1 ] values))

let test_queue_take_batch_admitted_sender_is_woken_even_if_resolver_raises () =
  check_admitted_sender_woken_after_resolver_failure (fun queue ->
      Queue.take_up_to queue ~max:1
      |> Effect.map (fun values ->
             Alcotest.(check (list int)) "drained values" [ 1 ] values))

let test_queue_close_senders_are_woken_even_if_resolver_raises () =
  let rt = Test_runtime.create () in
  let queue = setup_full_backpressure_queue_with_two_senders rt in
  with_first_resolver_failure @@ fun resolve_attempts ->
  (try Queue.close_with_error queue `Boom with Await_cancelled -> ());
  Alcotest.(check int) "all close wakeups resolved" 3 !resolve_attempts;
  let stats = Queue.stats queue in
  Alcotest.(check bool) "queue closed" true stats.Queue.closed;
  Alcotest.(check int) "no stranded sender" 0 stats.Queue.waiting_senders;
  Alcotest.(check int) "buffered value still drains" 1
    (run_ok rt (Queue.take queue));
  (match Test_runtime.run rt (Queue.take queue) with
  | Exit.Error (Cause.Fail (`Closed_with_error `Boom)) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected close error, got %a" (Cause.pp pp_hidden) cause
  | Exit.Ok value -> Alcotest.failf "unexpected value after close: %d" value)

let test_queue_shutdown_committed_result_survives_wakeup_failure () =
  let rt = Test_runtime.create () in
  let queue = Queue.bounded ~capacity:1 () in
  Alcotest.(check bool) "initial offer" true (run_ok rt (Queue.offer queue 1));
  expect_blocked (Test_runtime.run rt (Queue.offer queue 2));
  expect_blocked (Test_runtime.run rt (Queue.await_shutdown queue));
  with_first_resolver_failure @@ fun resolve_attempts ->
  Alcotest.(check unit) "shutdown returns committed result" ()
    (Queue.shutdown queue);
  Alcotest.(check int) "all shutdown wakeups resolved" 3 !resolve_attempts;
  let stats = Queue.stats queue in
  Alcotest.(check bool) "shutdown committed" true stats.Queue.shutdown;
  Alcotest.(check int) "buffer dropped" 0 stats.Queue.depth;
  Alcotest.(check int) "blocked sender removed" 0 stats.Queue.waiting_senders;
  Alcotest.(check int) "dropped count committed" 1 stats.Queue.dropped;
  Alcotest.(check unit) "await_shutdown observes commit" ()
    (run_ok rt (Queue.await_shutdown queue));
  (match Test_runtime.run rt (Queue.offer queue 3) with
  | Exit.Error (Cause.Fail `Closed) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected closed offer after shutdown, got %a"
        (Cause.pp pp_hidden) cause
  | Exit.Ok admitted ->
      Alcotest.failf "offer after committed shutdown returned %b" admitted)

let test_queue_unbounded_offer_never_reports_full () =
  let rt = Test_runtime.create () in
  let queue = Queue.unbounded () in
  for value = 1 to 100 do
    Alcotest.(check bool)
      (Printf.sprintf "offer %d" value)
      true
      (run_ok rt (Queue.offer queue value))
  done;
  Alcotest.(check int) "unbounded queue depth" 100
    (Queue.stats queue).Queue.depth;
  for expected = 1 to 100 do
    Alcotest.(check int)
      (Printf.sprintf "recv %d" expected)
      expected
      (run_ok rt (Queue.take queue))
  done

let test_queue_backpressure_offer_waits_instead_of_returning_full () =
  let rt = Test_runtime.create () in
  let queue = Queue.bounded ~capacity:1 () in
  Alcotest.(check bool) "initial offer" true (run_ok rt (Queue.offer queue 1));
  (match run_ok rt (Queue.try_offer queue 2) with
  | `Full -> ()
  | result ->
      Alcotest.failf "expected try_send to report Full, got %s"
        (match result with
        | `Sent -> "Sent"
        | `Dropped -> "Dropped"
        | `Full -> "Full"
        | `Closed -> "Closed"
        | `Closed_with_error _ -> "Closed_with_error"));
  expect_blocked (Test_runtime.run rt (Queue.offer queue 2));
  Alcotest.(check int) "waiting sender recorded" 1
    (Queue.stats queue).Queue.waiting_senders

let test_queue_recv_waits_instead_of_returning_empty () =
  let rt = Test_runtime.create () in
  let queue = Queue.unbounded () in
  (match run_ok rt (Queue.poll queue) with
  | `Empty -> ()
  | `Item _ -> Alcotest.fail "try_recv unexpectedly returned an item"
  | `Closed -> Alcotest.fail "try_recv unexpectedly reported clean close"
  | `Closed_with_error _ ->
      Alcotest.fail "try_recv unexpectedly reported error close");
  expect_blocked (Test_runtime.run rt (Queue.take queue));
  Alcotest.(check int) "waiting receiver recorded" 1
    (Queue.stats queue).Queue.waiting_receivers

let set_queue_counter queue field value =
  (* Public APIs cannot drive stats counters to [max_int] in a focused test. *)
  Obj.set_field (Obj.repr queue) field (Obj.repr value)

let test_queue_stats_counters_saturate () =
  let rt = Test_runtime.create () in
  let sent_queue = Queue.unbounded () in
  set_queue_counter sent_queue 8 (max_int - 1);
  run_ok rt (Queue.send sent_queue 1);
  run_ok rt (Queue.send sent_queue 2);
  Alcotest.(check int) "sent saturates" max_int
    (Queue.stats sent_queue).Queue.sent;
  let received_queue = Queue.unbounded () in
  run_ok rt (Queue.send received_queue 1);
  run_ok rt (Queue.send received_queue 2);
  set_queue_counter received_queue 9 (max_int - 1);
  Alcotest.(check int) "first received value" 1
    (run_ok rt (Queue.take received_queue));
  Alcotest.(check int) "second received value" 2
    (run_ok rt (Queue.take received_queue));
  Alcotest.(check int) "received saturates" max_int
    (Queue.stats received_queue).Queue.received;
  let dropped_queue = Queue.dropping ~capacity:1 () in
  run_ok rt (Queue.send dropped_queue 1);
  set_queue_counter dropped_queue 10 (max_int - 1);
  Alcotest.(check bool) "first drop" false
    (run_ok rt (Queue.offer dropped_queue 2));
  Alcotest.(check bool) "second drop" false
    (run_ok rt (Queue.offer dropped_queue 3));
  Alcotest.(check int) "dropped saturates" max_int
    (Queue.stats dropped_queue).Queue.dropped
