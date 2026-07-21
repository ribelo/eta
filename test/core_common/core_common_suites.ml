module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  open Eta

  module E = Effect
  module Effect_retry_repeat_suites = Effect_retry_repeat_common_suites.Make (B)
  module Effect_resource_timeout_suites =
    Effect_resource_timeout_common_suites.Make (B)
  module Effect_suites = Effect_common_suites.Make (B)
  module Effect_uninterruptible_suites =
    Effect_uninterruptible_common_suites.Make (B)
  module Observability_suites = Observability_common_suites.Make (B)
  module Pool_suites = Pool_common_suites.Make (B)
  module Properties_suites = Properties_common_suites.Make (B)
  module Resource_suites = Resource_common_suites.Make (B)
  module Stress_suites = Stress_common_suites.Make (B)
  module Supervisor_suites = Supervisor_common_suites.Make (B)
  module Upstream_invariants_suites = Upstream_invariants_common_suites.Make (B)

  let pp_hidden ppf _ = Format.pp_print_string ppf "<err>"

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

  let wait_until ?(attempts = 200) pred =
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

  let yield_effect () =
    E.Expert.make ~capabilities:[ `Concurrency ] ~leaf_name:"test.yield"
    @@ fun context ->
    let contract = E.Expert.contract context in
    contract.Runtime_contract.yield ();
    Exit.Ok ()

  let rec wait_until_effect ?(attempts = 200) pred =
    if pred () then E.unit
    else if attempts = 0 then E.sync (fun () -> Alcotest.fail "condition did not become true")
    else
      E.bind
        (fun () -> wait_until_effect ~attempts:(attempts - 1) pred)
        (yield_effect ())

  let publish_result =
    Alcotest.testable
      (fun fmt (result : Pubsub.publish_result) ->
        Format.fprintf fmt "{ subscriber_count = %d; dropped = %d }"
          result.subscriber_count result.dropped)
      ( = )

  let recv_result :
      (int, string) Pubsub.recv_result Alcotest.testable =
    Alcotest.testable
      (fun fmt -> function
        | `Item n -> Format.fprintf fmt "`Item %d" n
        | `Empty -> Format.pp_print_string fmt "`Empty"
        | `Closed -> Format.pp_print_string fmt "`Closed"
        | `Closed_with_error msg ->
            Format.fprintf fmt "`Closed_with_error %S" msg)
      ( = )

  let pp_close_result fmt = function
    | `Closed -> Format.pp_print_string fmt "`Closed"
    | `Closed_with_error msg ->
        Format.fprintf fmt "`Closed_with_error %S" msg

  let close_result :
      [ `Closed | `Closed_with_error of string ] Alcotest.testable =
    Alcotest.testable pp_close_result ( = )

  let wait_for_waiting_publisher hub =
    wait_until_effect (fun () ->
        (Pubsub.stats hub).Pubsub.waiting_publishers = 1)

  let wait_for_cancelled_publisher hub =
    wait_until_effect (fun () ->
        (Pubsub.stats hub).Pubsub.cancelled_publishers = 1)

  let wait_for_waiting_queue_sender queue =
    wait_until_effect (fun () ->
        (Queue.stats queue).Queue.waiting_senders = 1)

  let wait_for_cancelled_queue_sender queue =
    wait_until_effect (fun () ->
        (Queue.stats queue).Queue.cancelled_senders = 1)

  let expect_closed rt eff =
    expect_fail "closed" (( = ) `Closed) (B.run rt eff)

  let retained_bytes_since base_words =
    Gc.full_major ();
    let live_words = (Gc.stat ()).Gc.live_words - base_words in
    max 0 live_words * (Sys.word_size / 8)

  let expect_cancelled label = function
    | `Cancelled -> ()
    | `Returned (Exit.Ok _) ->
        Alcotest.failf "%s: expected cancellation, got Ok" label
    | `Returned (Exit.Error cause) ->
        Alcotest.failf "%s: expected cancellation, got %a" label
          (Cause.pp pp_hidden) cause

  let test_mutable_ref_make_get () =
    let r = Mutable_ref.make 42 in
    Alcotest.(check int) "make then get" 42 (Mutable_ref.get r)

  let test_mutable_ref_set () =
    let r = Mutable_ref.make 0 in
    Mutable_ref.set r 7;
    Alcotest.(check int) "set overwrites" 7 (Mutable_ref.get r)

  let test_mutable_ref_update () =
    let r = Mutable_ref.make 1 in
    Mutable_ref.update r (fun x -> x + 2);
    Alcotest.(check int) "update applies function" 3 (Mutable_ref.get r)

  let test_mutable_ref_update_and_get () =
    let r = Mutable_ref.make 5 in
    let v = Mutable_ref.update_and_get r (fun x -> x * 2) in
    Alcotest.(check int) "update_and_get returns new" 10 v;
    Alcotest.(check int) "update_and_get stores new" 10 (Mutable_ref.get r)

  let test_mutable_ref_get_and_set () =
    let r = Mutable_ref.make 3 in
    let old = Mutable_ref.get_and_set r 9 in
    Alcotest.(check int) "get_and_set returns old" 3 old;
    Alcotest.(check int) "get_and_set stores new" 9 (Mutable_ref.get r)

  let test_mutable_ref_compare_and_set () =
    let r = Mutable_ref.make "a" in
    let expected = Mutable_ref.get r in
    let ok = Mutable_ref.compare_and_set r expected "b" in
    Alcotest.(check bool) "cas succeeds when expected matches" true ok;
    Alcotest.(check string) "cas stores desired" "b" (Mutable_ref.get r);
    let failed = Mutable_ref.compare_and_set r "a" "c" in
    Alcotest.(check bool) "cas fails when expected mismatches" false failed;
    Alcotest.(check string) "cas leaves value on failure" "b" (Mutable_ref.get r)

  let test_mutable_ref_concurrent_update () =
    B.with_runtime @@ fun _ctx rt ->
    let r = Mutable_ref.make 0 in
    let updates = 10_000 in
    let worker =
      E.sync (fun () ->
          for _ = 1 to updates do
            Mutable_ref.update r (fun x -> x + 1)
          done)
    in
    ignore (run_ok rt (E.par worker worker) : unit * unit);
    Alcotest.(check int) "concurrent updates converge" (2 * updates)
      (Mutable_ref.get r)

  let test_mutable_ref_incr_decr () =
    let r = Mutable_ref.make 0 in
    Mutable_ref.incr r;
    Alcotest.(check int) "incr" 1 (Mutable_ref.get r);
    Mutable_ref.decr r;
    Alcotest.(check int) "decr" 0 (Mutable_ref.get r);
    Mutable_ref.decr r;
    Alcotest.(check int) "decr again" (-1) (Mutable_ref.get r)

  let test_queue_send_recv_close () =
    B.with_runtime @@ fun _ctx rt ->
    let q = Queue.unbounded () in
    ignore (run_ok rt (Queue.send q 1) : unit);
    ignore (run_ok rt (Queue.send q 2) : unit);
    Queue.close q;
    Alcotest.(check int) "first" 1 (run_ok rt (Queue.take q));
    Alcotest.(check int) "second" 2 (run_ok rt (Queue.take q));
    expect_fail "clean close" (( = ) `Closed) (B.run rt (Queue.take q));
    let stats = Queue.stats q in
    Alcotest.(check int) "sent" 2 stats.Queue.sent;
    Alcotest.(check int) "received" 2 stats.Queue.received

  let test_queue_close_fence () =
    B.with_runtime @@ fun _ctx rt ->
    let q = Queue.unbounded () in
    Queue.close q;
    (match run_ok rt (Queue.try_offer q 1) with
    | `Closed -> ()
    | _ -> Alcotest.fail "expected closed send");
    (match run_ok rt (Queue.poll q) with
    | `Closed -> ()
    | _ -> Alcotest.fail "expected closed recv");
    Alcotest.(check int) "depth" 0 (Queue.stats q).depth

  let test_queue_close_with_error_drains () =
    B.with_runtime @@ fun _ctx rt ->
    let q = Queue.unbounded () in
    ignore (run_ok rt (Queue.send q "buffered") : unit);
    Queue.close_with_error q "provider failed";
    Alcotest.(check string) "buffered" "buffered" (run_ok rt (Queue.take q));
    expect_fail "close_with_error"
      (function `Closed_with_error "provider failed" -> true | _ -> false)
      (B.run rt (Queue.take q))

  let test_queue_timeout_blocked_recv_cleans_waiter () =
    B.with_test_clock @@ fun ctx clock rt ->
    let q = Queue.unbounded () in
    let receiver =
      B.fork_run ctx rt
        (Queue.take q |> E.timeout_as (Duration.ms 5) ~on_timeout:`Timeout)
    in
    wait_until (fun () -> (Queue.stats q).Queue.waiting_receivers = 1);
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    expect_fail "timeout" (( = ) `Timeout) (B.await receiver);
    let stats = Queue.stats q in
    Alcotest.(check int) "waiting receivers" 0 stats.Queue.waiting_receivers;
    Alcotest.(check int) "cancelled receivers" 1 stats.Queue.cancelled_receivers;
    ignore (run_ok rt (Queue.send q 42) : unit);
    Alcotest.(check int) "next recv gets sent value" 42 (run_ok rt (Queue.take q))

  let test_queue_cancel_blocked_recv_cleans_waiter () =
    B.with_runtime @@ fun ctx rt ->
    let q = Queue.unbounded () in
    let receiver = B.fork_run_cancelable ctx rt (Queue.take q) in
    wait_until (fun () -> (Queue.stats q).Queue.waiting_receivers = 1);
    B.cancel_fiber receiver;
    expect_cancelled "receiver" (B.await_cancelable receiver);
    let stats = Queue.stats q in
    Alcotest.(check int) "waiting receivers" 0 stats.Queue.waiting_receivers;
    Alcotest.(check int) "cancelled receivers" 1 stats.Queue.cancelled_receivers

  let test_queue_offer_unbounded_create_and_alias () =
    B.with_runtime @@ fun _ctx rt ->
    let created = Queue.unbounded () in
    let unbounded = Queue.unbounded () in
    Alcotest.(check bool) "created offer" true
      (run_ok rt (Queue.offer created 1));
    Alcotest.(check bool) "unbounded offer" true
      (run_ok rt (Queue.offer unbounded 2));
    Alcotest.(check (list int)) "unbounded offer_all leftovers" []
      (run_ok rt (Queue.offer_all created [ 3; 4 ]));
    Alcotest.(check int) "created recv" 1 (run_ok rt (Queue.take created));
    Alcotest.(check (list int)) "created remaining" [ 3; 4 ]
      (run_ok rt (Queue.take_all created));
    Alcotest.(check int) "unbounded recv" 2 (run_ok rt (Queue.take unbounded))

  let test_queue_named_constructors_and_views () =
    B.with_runtime @@ fun _ctx rt ->
    let q = Queue.bounded ~capacity:1 () in
    let producer = Queue.enqueue q in
    let consumer = Queue.dequeue q in
    Alcotest.(check (option int)) "capacity" (Some 1) (Queue.capacity q);
    Alcotest.(check bool) "initial empty" true (Queue.Dequeue.is_empty consumer);
    Alcotest.(check bool)
      "offered through view" true
      (run_ok rt (Queue.Enqueue.offer producer 11));
    Alcotest.(check bool) "full through view" true (Queue.Enqueue.is_full producer);
    Alcotest.(check int)
      "taken through view" 11
      (run_ok rt (Queue.Dequeue.take consumer));
    Alcotest.(check bool) "empty after take" true (Queue.is_empty q)

  let test_queue_sliding_keeps_latest_capacity () =
    B.with_runtime @@ fun _ctx rt ->
    let q = Queue.sliding ~capacity:2 () in
    Alcotest.(check (list int))
      "no leftovers" []
      (run_ok rt (Queue.offer_all q [ 1; 2; 3; 4 ]));
    Alcotest.(check (list int))
      "latest retained" [ 3; 4 ]
      (run_ok rt (Queue.take_all q));
    let stats = Queue.stats q in
    Alcotest.(check int) "dropped old values" 2 stats.Queue.dropped;
    Alcotest.(check int) "sent all offers" 4 stats.Queue.sent;
    Alcotest.(check int) "received retained values" 2 stats.Queue.received

  let test_queue_logical_size_tracks_waiters () =
    B.with_runtime @@ fun ctx rt ->
    let q = Queue.unbounded () in
    let receiver = B.fork_run ctx rt (Queue.take q) in
    wait_until (fun () -> (Queue.stats q).Queue.waiting_receivers = 1);
    Alcotest.(check int) "waiting receiver makes size negative" (-1)
      (Queue.size q);
    Alcotest.(check bool) "logically empty" true (Queue.is_empty q);
    Queue.close q;
    expect_fail "receiver closed" (( = ) `Closed) (B.await receiver);
    let bounded = Queue.bounded ~capacity:1 () in
    ignore (run_ok rt (Queue.send bounded 1) : unit);
    let sender = B.fork_run ctx rt (Queue.offer bounded 2) in
    run_ok rt (wait_for_waiting_queue_sender bounded);
    Alcotest.(check int) "waiting sender contributes pressure" 2
      (Queue.size bounded);
    Alcotest.(check bool) "logically full" true (Queue.is_full bounded);
    Alcotest.(check int) "first value" 1 (run_ok rt (Queue.take bounded));
    check_exit_ok Alcotest.bool "blocked offer admitted" true (B.await sender);
    Alcotest.(check int) "second value" 2 (run_ok rt (Queue.take bounded))

  let test_queue_shutdown_is_immediate () =
    B.with_runtime @@ fun ctx rt ->
    let q = Queue.unbounded () in
    let receiver = B.fork_run ctx rt (Queue.take q) in
    wait_until (fun () -> (Queue.stats q).Queue.waiting_receivers = 1);
    Queue.shutdown q;
    expect_fail "blocked receiver closed" (( = ) `Closed) (B.await receiver);
    Alcotest.(check bool) "shutdown" true (Queue.is_shutdown q);
    expect_fail "future offer closed" (( = ) `Closed)
      (B.run rt (Queue.offer q 2));
    expect_fail "future take closed" (( = ) `Closed) (B.run rt (Queue.take q));
    expect_fail "future take_all closed" (( = ) `Closed)
      (B.run rt (Queue.take_all q));
    expect_fail "future zero take_up_to closed" (( = ) `Closed)
      (B.run rt (Queue.take_up_to q ~max:0));
    ignore (run_ok rt (Queue.await_shutdown q) : unit);
    let buffered = Queue.unbounded () in
    ignore (run_ok rt (Queue.send buffered 1) : unit);
    Queue.shutdown buffered;
    Alcotest.(check int)
      "buffered value dropped" 1
      (Queue.stats buffered).Queue.dropped;
    expect_fail "buffered value not drainable" (( = ) `Closed)
      (B.run rt (Queue.take buffered))

  let test_queue_drop_new_reports_admission_result () =
    B.with_runtime @@ fun _ctx rt ->
    let q = Queue.dropping ~capacity:2 () in
    Alcotest.(check bool) "first" true
      (run_ok rt (Queue.offer q 1));
    Alcotest.(check bool) "second" true
      (run_ok rt (Queue.offer q 2));
    Alcotest.(check bool) "third dropped" false
      (run_ok rt (Queue.offer q 3));
    Alcotest.(check (list int)) "offer_all leftovers" [ 4; 5 ]
      (run_ok rt (Queue.offer_all q [ 4; 5 ]));
    (match run_ok rt (Queue.try_offer q 4) with
    | `Dropped -> ()
    | result ->
        Alcotest.failf "expected try_send drop, got %s"
          (match result with
          | `Sent -> "`Sent"
          | `Full -> "`Full"
          | `Closed -> "`Closed"
          | `Closed_with_error _ -> "`Closed_with_error"
          | `Dropped -> assert false));
    Alcotest.(check (list int)) "retained first two" [ 1; 2 ]
      (run_ok rt (Queue.take_all q));
    let stats = Queue.stats q in
    Alcotest.(check int) "sent" 2 stats.Queue.sent;
    Alcotest.(check int) "dropped" 4 stats.Queue.dropped;
    Alcotest.(check int) "received" 2 stats.Queue.received

  let test_queue_send_drop_new_fails_on_rejection () =
    B.with_runtime @@ fun _ctx rt ->
    let q = Queue.dropping ~capacity:1 () in
    ignore (run_ok rt (Queue.send q 1) : unit);
    expect_fail "send dropped" (( = ) `Dropped) (B.run rt (Queue.send q 2));
    Alcotest.(check (list int)) "only admitted value remains" [ 1 ]
      (run_ok rt (Queue.take_all q));
    let stats = Queue.stats q in
    Alcotest.(check int) "sent" 1 stats.Queue.sent;
    Alcotest.(check int) "dropped" 1 stats.Queue.dropped

  let test_queue_backpressure_offer_waits_for_capacity () =
    B.with_runtime @@ fun ctx rt ->
    let q = Queue.bounded ~capacity:1 () in
    Alcotest.(check bool) "first" true
      (run_ok rt (Queue.offer q 1));
    let sender = B.fork_run ctx rt (Queue.offer q 2) in
    run_ok rt (wait_for_waiting_queue_sender q);
    Alcotest.(check int) "depth while blocked" 1 (Queue.stats q).Queue.depth;
    Alcotest.(check int) "first recv" 1 (run_ok rt (Queue.take q));
    check_exit_ok Alcotest.bool "sender admitted" true (B.await sender);
    Alcotest.(check int) "second recv" 2 (run_ok rt (Queue.take q))

  let test_queue_backpressure_try_send_reports_full () =
    B.with_runtime @@ fun _ctx rt ->
    let q = Queue.bounded ~capacity:1 () in
    Alcotest.(check bool) "first" true
      (run_ok rt (Queue.offer q 1));
    (match run_ok rt (Queue.try_offer q 2) with
    | `Full -> ()
    | _ -> Alcotest.fail "expected full try_send result");
    Alcotest.(check int) "only first value" 1 (run_ok rt (Queue.take q));
    (match run_ok rt (Queue.poll q) with
    | `Empty -> ()
    | _ -> Alcotest.fail "expected empty after full try_send")

  let test_queue_backpressure_cancel_blocked_offer () =
    B.with_runtime @@ fun ctx rt ->
    let q = Queue.bounded ~capacity:1 () in
    Alcotest.(check bool) "first" true
      (run_ok rt (Queue.offer q 1));
    let sender = B.fork_run_cancelable ctx rt (Queue.offer q 2) in
    run_ok rt (wait_for_waiting_queue_sender q);
    B.cancel_fiber sender;
    expect_cancelled "queue sender" (B.await_cancelable sender);
    run_ok rt (wait_for_cancelled_queue_sender q);
    let stats = Queue.stats q in
    Alcotest.(check int) "waiting senders" 0 stats.Queue.waiting_senders;
    Alcotest.(check int) "cancelled senders" 1 stats.Queue.cancelled_senders;
    Alcotest.(check int) "depth unchanged" 1 stats.Queue.depth;
    Alcotest.(check int) "original value" 1 (run_ok rt (Queue.take q));
    (match run_ok rt (Queue.poll q) with
    | `Empty -> ()
    | _ -> Alcotest.fail "cancelled offer enqueued a value")

  let test_queue_close_wakes_blocked_offer () =
    B.with_runtime @@ fun ctx rt ->
    let q = Queue.bounded ~capacity:1 () in
    ignore (run_ok rt (Queue.send q 1) : unit);
    let sender = B.fork_run ctx rt (Queue.offer q 2) in
    run_ok rt (wait_for_waiting_queue_sender q);
    Queue.close q;
    expect_fail "blocked offer closed" (( = ) `Closed) (B.await sender);
    let stats = Queue.stats q in
    Alcotest.(check int) "waiting senders" 0 stats.Queue.waiting_senders

  let test_queue_offer_closed_failures () =
    B.with_runtime @@ fun _ctx rt ->
    let clean = Queue.unbounded () in
    Queue.close clean;
    expect_fail "offer closed" (( = ) `Closed) (B.run rt (Queue.offer clean 1));
    expect_fail "offer_all closed" (( = ) `Closed)
      (B.run rt (Queue.offer_all clean [ 1; 2 ]));
    let failed = Queue.unbounded () in
    Queue.close_with_error failed "provider failed";
    expect_fail "offer close_with_error"
      (function `Closed_with_error "provider failed" -> true | _ -> false)
      (B.run rt (Queue.offer failed 1));
    expect_fail "offer_all close_with_error"
      (function `Closed_with_error "provider failed" -> true | _ -> false)
      (B.run rt (Queue.offer_all failed [ 1; 2 ]))

  let test_queue_close_with_error_wakes_blocked_offer () =
    B.with_runtime @@ fun ctx rt ->
    let q = Queue.bounded ~capacity:1 () in
    ignore (run_ok rt (Queue.send q 1) : unit);
    let sender = B.fork_run ctx rt (Queue.offer q 2) in
    run_ok rt (wait_for_waiting_queue_sender q);
    Queue.close_with_error q "provider failed";
    expect_fail "blocked offer close_with_error"
      (function `Closed_with_error "provider failed" -> true | _ -> false)
      (B.await sender);
    let stats = Queue.stats q in
    Alcotest.(check int) "waiting senders" 0 stats.Queue.waiting_senders

  let test_queue_take_all_and_batch_drain () =
    B.with_runtime @@ fun _ctx rt ->
    let q = Queue.unbounded () in
    ignore (run_ok rt (Queue.send q 1) : unit);
    ignore (run_ok rt (Queue.send q 2) : unit);
    ignore (run_ok rt (Queue.send q 3) : unit);
    Alcotest.(check (list int)) "batch first two" [ 1; 2 ]
      (run_ok rt (Queue.take_up_to q ~max:2));
    Alcotest.(check (list int)) "take rest" [ 3 ]
      (run_ok rt (Queue.take_all q));
    Alcotest.(check (list int)) "open empty" [] (run_ok rt (Queue.take_all q));
    Queue.close q;
    expect_fail "closed take_all" (( = ) `Closed) (B.run rt (Queue.take_all q))

  let test_queue_take_all_opens_backpressure_capacity () =
    B.with_runtime @@ fun ctx rt ->
    let q = Queue.bounded ~capacity:2 () in
    ignore (run_ok rt (Queue.send q 1) : unit);
    ignore (run_ok rt (Queue.send q 2) : unit);
    let sender = B.fork_run ctx rt (Queue.offer_all q [ 3; 4 ]) in
    run_ok rt (wait_for_waiting_queue_sender q);
    Alcotest.(check (list int)) "drained initial values" [ 1; 2 ]
      (run_ok rt (Queue.take_all q));
    check_exit_ok Alcotest.(list int) "blocked offer_all admitted" []
      (B.await sender);
    Alcotest.(check (list int)) "next values" [ 3; 4 ]
      (run_ok rt (Queue.take_all q))

  let test_queue_bounded_capacity_rejects_non_positive () =
    Alcotest.check_raises "dropping zero"
      (Invalid_argument "Eta.Queue.dropping: capacity must be > 0")
      (fun () ->
        ignore (Queue.dropping ~capacity:0 ()));
    Alcotest.check_raises "backpressure zero"
      (Invalid_argument "Eta.Queue.bounded: capacity must be > 0")
      (fun () ->
        ignore
          (Queue.bounded ~capacity:0 ()))

  let test_channel_try_send_try_recv () =
    B.with_runtime @@ fun _ctx rt ->
    let ch = Channel.create ~capacity:1 () in
    (match run_ok rt (Channel.try_recv ch) with
    | `Empty -> ()
    | _ -> Alcotest.fail "expected empty");
    (match run_ok rt (Channel.try_send ch 1) with
    | `Sent -> ()
    | _ -> Alcotest.fail "expected sent");
    (match run_ok rt (Channel.try_send ch 2) with
    | `Full -> ()
    | _ -> Alcotest.fail "expected full");
    (match run_ok rt (Channel.try_recv ch) with
    | `Item 1 -> ()
    | _ -> Alcotest.fail "expected item");
    let stats = Channel.stats ch in
    Alcotest.(check int) "sent" 1 stats.Channel.sent;
    Alcotest.(check int) "received" 1 stats.Channel.received

  let test_channel_fifo_send_recv () =
    B.with_runtime @@ fun _ctx rt ->
    let ch = Channel.create ~capacity:3 () in
    ignore (run_ok rt (Channel.send ch 1) : unit);
    ignore (run_ok rt (Channel.send ch 2) : unit);
    ignore (run_ok rt (Channel.send ch 3) : unit);
    Alcotest.(check int) "first" 1 (run_ok rt (Channel.recv ch));
    Alcotest.(check int) "second" 2 (run_ok rt (Channel.recv ch));
    Alcotest.(check int) "third" 3 (run_ok rt (Channel.recv ch))

  let test_channel_blocking_send_backpressure () =
    B.with_runtime @@ fun ctx rt ->
    let ch = Channel.create ~capacity:1 () in
    ignore (run_ok rt (Channel.send ch 1) : unit);
    let sender = B.fork_run ctx rt (Channel.send ch 2) in
    wait_until (fun () -> (Channel.stats ch).Channel.waiting_senders = 1);
    Alcotest.(check int) "depth while blocked" 1 (Channel.stats ch).depth;
    Alcotest.(check int) "first recv" 1 (run_ok rt (Channel.recv ch));
    check_exit_ok Alcotest.unit "sender completed" () (B.await sender);
    Alcotest.(check int) "second recv" 2 (run_ok rt (Channel.recv ch))

  let test_channel_blocked_sender_is_not_passed_by_later_sender () =
    B.with_runtime @@ fun ctx rt ->
    let ch = Channel.create ~capacity:1 () in
    ignore (run_ok rt (Channel.send ch 1) : unit);
    let first_sender = B.fork_run ctx rt (Channel.send ch 2) in
    wait_until (fun () -> (Channel.stats ch).Channel.waiting_senders = 1);
    Alcotest.(check int) "initial value" 1 (run_ok rt (Channel.recv ch));
    check_exit_ok Alcotest.unit "first sender admitted" ()
      (B.await first_sender);
    let later_sender = B.fork_run ctx rt (Channel.send ch 3) in
    wait_until (fun () -> (Channel.stats ch).Channel.waiting_senders = 1);
    Alcotest.(check int) "blocked sender value" 2 (run_ok rt (Channel.recv ch));
    check_exit_ok Alcotest.unit "later sender admitted" ()
      (B.await later_sender);
    Alcotest.(check int) "later value" 3 (run_ok rt (Channel.recv ch))

  let test_channel_blocking_recv () =
    B.with_runtime @@ fun ctx rt ->
    let ch = Channel.create ~capacity:1 () in
    let receiver = B.fork_run ctx rt (Channel.recv ch) in
    wait_until (fun () -> (Channel.stats ch).Channel.waiting_receivers = 1);
    ignore (run_ok rt (Channel.send ch 7) : unit);
    check_exit_ok Alcotest.int "received" 7 (B.await receiver)

  let test_channel_close_wakes_blocked_senders_and_receivers () =
    B.with_runtime @@ fun ctx rt ->
    let sender_ch = Channel.create ~capacity:1 () in
    ignore (run_ok rt (Channel.send sender_ch 1) : unit);
    let sender = B.fork_run ctx rt (Channel.send sender_ch 2) in
    wait_until (fun () -> (Channel.stats sender_ch).Channel.waiting_senders = 1);
    Channel.close sender_ch;
    expect_fail "blocked sender closed" (( = ) `Closed) (B.await sender);
    let receiver_ch = Channel.create ~capacity:1 () in
    let receiver = B.fork_run ctx rt (Channel.recv receiver_ch) in
    wait_until (fun () -> (Channel.stats receiver_ch).Channel.waiting_receivers = 1);
    Channel.close receiver_ch;
    expect_fail "blocked receiver closed" (( = ) `Closed) (B.await receiver)

  let test_channel_close_with_error_drains_buffer () =
    B.with_runtime @@ fun _ctx rt ->
    let ch = Channel.create ~capacity:1 () in
    ignore (run_ok rt (Channel.send ch 1) : unit);
    Channel.close_with_error ch `Boom;
    Alcotest.(check int) "buffered value" 1 (run_ok rt (Channel.recv ch));
    expect_fail "close_with_error after drain"
      (function `Closed_with_error `Boom -> true | _ -> false)
      (B.run rt (Channel.recv ch));
    (match run_ok rt (Channel.try_send ch 2) with
    | `Closed_with_error `Boom -> ()
    | _ -> Alcotest.fail "expected try_send to see close_with_error")

  let test_channel_close_drains_buffer_then_reports_closed () =
    B.with_runtime @@ fun _ctx rt ->
    let ch = Channel.create ~capacity:2 () in
    ignore (run_ok rt (Channel.send ch 1) : unit);
    ignore (run_ok rt (Channel.send ch 2) : unit);
    Channel.close ch;
    Alcotest.(check int) "first buffered" 1 (run_ok rt (Channel.recv ch));
    Alcotest.(check int) "second buffered" 2 (run_ok rt (Channel.recv ch));
    expect_fail "closed after buffered values drain" (( = ) `Closed)
      (B.run rt (Channel.recv ch));
    (match run_ok rt (Channel.try_recv ch) with
    | `Closed -> ()
    | _ -> Alcotest.fail "expected try_recv to report closed after drain")

  let test_channel_timeout_blocked_send_cleans_waiter () =
    B.with_test_clock @@ fun ctx clock rt ->
    let ch = Channel.create ~capacity:1 () in
    ignore (run_ok rt (Channel.send ch 1) : unit);
    let sender =
      B.fork_run ctx rt
        (Channel.send ch 2 |> E.timeout_as (Duration.ms 5) ~on_timeout:`Timeout)
    in
    wait_until (fun () -> (Channel.stats ch).Channel.waiting_senders = 1);
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    expect_fail "timeout" (( = ) `Timeout) (B.await sender);
    let stats = Channel.stats ch in
    Alcotest.(check int) "waiting senders" 0 stats.Channel.waiting_senders;
    Alcotest.(check int) "cancelled senders" 1 stats.Channel.cancelled_senders;
    Alcotest.(check int) "depth unchanged" 1 stats.Channel.depth;
    Alcotest.(check int) "original value" 1 (run_ok rt (Channel.recv ch));
    (match run_ok rt (Channel.try_recv ch) with
    | `Empty -> ()
    | _ -> Alcotest.fail "timed-out sender enqueued a value")

  let test_channel_timeout_blocked_recv_cleans_waiter () =
    B.with_test_clock @@ fun ctx clock rt ->
    let ch = Channel.create ~capacity:1 () in
    let receiver =
      B.fork_run ctx rt
        (Channel.recv ch |> E.timeout_as (Duration.ms 5) ~on_timeout:`Timeout)
    in
    wait_until (fun () -> (Channel.stats ch).Channel.waiting_receivers = 1);
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    expect_fail "timeout" (( = ) `Timeout) (B.await receiver);
    Alcotest.(check int)
      "waiting receivers" 0 (Channel.stats ch).Channel.waiting_receivers;
    ignore (run_ok rt (Channel.send ch 42) : unit);
    Alcotest.(check int) "next receiver gets value" 42 (run_ok rt (Channel.recv ch))

  let test_channel_cancel_blocked_send_cleans_waiter () =
    B.with_runtime @@ fun ctx rt ->
    let ch = Channel.create ~capacity:1 () in
    ignore (run_ok rt (Channel.send ch 1) : unit);
    let sender = B.fork_run_cancelable ctx rt (Channel.send ch 2) in
    wait_until (fun () -> (Channel.stats ch).Channel.waiting_senders = 1);
    B.cancel_fiber sender;
    expect_cancelled "sender" (B.await_cancelable sender);
    let stats = Channel.stats ch in
    Alcotest.(check int) "waiting senders" 0 stats.Channel.waiting_senders;
    Alcotest.(check int) "cancelled senders" 1 stats.Channel.cancelled_senders;
    Alcotest.(check int) "depth unchanged" 1 stats.Channel.depth;
    Alcotest.(check int) "original value" 1 (run_ok rt (Channel.recv ch));
    match run_ok rt (Channel.try_recv ch) with
    | `Empty -> ()
    | _ -> Alcotest.fail "cancelled sender enqueued a value"

  let test_channel_cancelled_blocked_senders_release_payloads () =
    B.with_runtime @@ fun ctx rt ->
    let ch = Channel.create ~capacity:1 () in
    ignore (run_ok rt (Channel.send ch (Bytes.create 1)) : unit);
    Gc.full_major ();
    let base_words = (Gc.stat ()).Gc.live_words in
    for _ = 1 to 32 do
      let sender =
        B.fork_run_cancelable ctx rt
          (Channel.send ch (Bytes.make (1024 * 1024) 'x'))
      in
      wait_until (fun () -> (Channel.stats ch).Channel.waiting_senders = 1);
      B.cancel_fiber sender;
      expect_cancelled "sender" (B.await_cancelable sender)
    done;
    let retained = retained_bytes_since base_words in
    Alcotest.(check bool)
      "cancelled sender payloads released" true
      (retained < (4 * 1024 * 1024))

  let test_channel_cancel_blocked_recv_cleans_waiter () =
    B.with_runtime @@ fun ctx rt ->
    let ch = Channel.create ~capacity:1 () in
    let receiver = B.fork_run_cancelable ctx rt (Channel.recv ch) in
    wait_until (fun () -> (Channel.stats ch).Channel.waiting_receivers = 1);
    B.cancel_fiber receiver;
    expect_cancelled "receiver" (B.await_cancelable receiver);
    Alcotest.(check int)
      "waiting receivers" 0 (Channel.stats ch).Channel.waiting_receivers

  let test_semaphore_make_available () =
    let sem = Semaphore.make ~permits:8 in
    Alcotest.(check int) "available 8" 8 (Semaphore.available sem)

  let test_semaphore_make_rejects_zero_permits () =
    Alcotest.check_raises "zero permits"
      (Invalid_argument "Eta.Semaphore.make: permits must be > 0")
      (fun () -> ignore (Semaphore.make ~permits:0))

  let test_semaphore_acquire_reduces_available () =
    B.with_runtime @@ fun _ctx rt ->
    let sem = Semaphore.make ~permits:8 in
    ignore (run_ok rt (Semaphore.acquire sem 1) : unit);
    Alcotest.(check int) "available 7" 7 (Semaphore.available sem)

  let test_semaphore_release_increases_available () =
    B.with_runtime @@ fun _ctx rt ->
    let sem = Semaphore.make ~permits:8 in
    ignore (run_ok rt (Semaphore.acquire sem 1) : unit);
    Semaphore.release sem 1;
    Alcotest.(check int) "available 8" 8 (Semaphore.available sem)

  let test_semaphore_release_rejects_negative_count () =
    let sem = Semaphore.make ~permits:2 in
    Alcotest.check_raises "negative release"
      (Invalid_argument "Eta.Semaphore.release: n must be > 0")
      (fun () -> Semaphore.release sem (-1))

  let test_semaphore_release_rejects_zero_count () =
    let sem = Semaphore.make ~permits:2 in
    Alcotest.check_raises "zero release"
      (Invalid_argument "Eta.Semaphore.release: n must be > 0")
      (fun () -> Semaphore.release sem 0)

  let test_semaphore_release_rejects_over_capacity () =
    let sem = Semaphore.make ~permits:2 in
    Alcotest.check_raises "release over capacity"
      (Invalid_argument
         "Eta.Semaphore.release: release would exceed semaphore capacity")
      (fun () -> Semaphore.release sem 3)

  let test_semaphore_rejects_over_capacity_acquire () =
    let sem = Semaphore.make ~permits:2 in
    Alcotest.check_raises "acquire over capacity"
      (Invalid_argument
         "Eta.Semaphore.acquire: n must be between 1 and max_permits")
      (fun () -> ignore (Semaphore.acquire sem 3 : (unit, _) E.t))

  let test_semaphore_rejects_over_capacity_try_acquire () =
    let sem = Semaphore.make ~permits:2 in
    Alcotest.check_raises "try_acquire over capacity"
      (Invalid_argument
         "Eta.Semaphore.try_acquire: n must be between 1 and max_permits")
      (fun () -> ignore (Semaphore.try_acquire sem 3 : bool))

  let test_semaphore_acquire_at_capacity_succeeds () =
    B.with_runtime @@ fun _ctx rt ->
    let sem = Semaphore.make ~permits:2 in
    ignore (run_ok rt (Semaphore.acquire sem 2) : unit);
    Alcotest.(check int) "available 0" 0 (Semaphore.available sem)

  let test_semaphore_try_acquire_is_atomic () =
    let sem = Semaphore.make ~permits:3 in
    Alcotest.(check bool) "first acquire succeeds" true
      (Semaphore.try_acquire sem 2);
    Alcotest.(check int) "one permit remains" 1 (Semaphore.available sem);
    Alcotest.(check bool) "oversized acquire fails" false
      (Semaphore.try_acquire sem 2);
    Alcotest.(check int) "failed acquire did not decrement" 1
      (Semaphore.available sem);
    Alcotest.(check bool) "remaining permit succeeds" true
      (Semaphore.try_acquire sem 1);
    Alcotest.(check int) "empty" 0 (Semaphore.available sem)

  let test_semaphore_try_acquire_does_not_barge_queued_waiter () =
    B.with_runtime @@ fun ctx rt ->
    let sem = Semaphore.make ~permits:2 in
    Alcotest.(check bool) "initial acquire" true (Semaphore.try_acquire sem 2);
    let waiter = B.fork_run ctx rt (Semaphore.acquire sem 2) in
    wait_until (fun () -> Semaphore.waiting sem = 1);
    Semaphore.release sem 1;
    Alcotest.(check bool) "queued waiter remains blocked" false
      (B.is_resolved waiter);
    Alcotest.(check bool)
      "try_acquire must not barge ahead of queued waiter"
      false
      (Semaphore.try_acquire sem 1);
    Semaphore.release sem 1;
    check_exit_ok Alcotest.unit "older waiter receives permits" ()
      (B.await waiter);
    Semaphore.release sem 2

  let test_semaphore_acquire_does_not_barge_waiters () =
    B.with_runtime @@ fun ctx rt ->
    let sem = Semaphore.make ~permits:2 in
    ignore (run_ok rt (Semaphore.acquire sem 1) : unit);
    let first_started = ref false in
    let second_started = ref false in
    let first =
      B.fork_run ctx rt
        (E.sync (fun () -> first_started := true)
         |> E.bind (fun () -> Semaphore.acquire sem 2)
         |> E.map (fun () -> "first"))
    in
    wait_until (fun () -> !first_started);
    wait_until (fun () -> Semaphore.waiting sem = 1);
    let second =
      B.fork_run ctx rt
        (E.sync (fun () -> second_started := true)
         |> E.bind (fun () -> Semaphore.acquire sem 1)
         |> E.map (fun () -> "second"))
    in
    wait_until (fun () -> !second_started);
    B.yield ();
    Alcotest.(check bool) "first waits" false (B.is_resolved first);
    Alcotest.(check bool) "second must not barge" false (B.is_resolved second);
    Semaphore.release sem 1;
    check_exit_ok Alcotest.string "first acquired" "first" (B.await first);
    B.yield ();
    Alcotest.(check bool)
      "second waits while first owns both permits" false
      (B.is_resolved second);
    Semaphore.release sem 2;
    check_exit_ok Alcotest.string "second acquired" "second" (B.await second);
    Semaphore.release sem 1

  let test_semaphore_with_permits_releases_on_success () =
    B.with_runtime @@ fun _ctx rt ->
    let sem = Semaphore.make ~permits:5 in
    let result =
      run_ok rt (Semaphore.with_permits sem 3 (fun () -> E.pure "done"))
    in
    Alcotest.(check string) "result" "done" result;
    Alcotest.(check int) "available 5" 5 (Semaphore.available sem)

  let test_semaphore_with_permits_releases_on_failure () =
    B.with_runtime @@ fun _ctx rt ->
    let sem = Semaphore.make ~permits:5 in
    let eff =
      Semaphore.with_permits sem 3 (fun () -> E.fail `Boom)
      |> E.bind_error (fun (`Boom : [ `Boom ]) -> E.pure "caught")
    in
    let result = run_ok rt eff in
    Alcotest.(check string) "caught" "caught" result;
    Alcotest.(check int) "available 5" 5 (Semaphore.available sem)

  let test_semaphore_with_permits_releases_on_defect () =
    B.with_runtime @@ fun _ctx rt ->
    let sem = Semaphore.make ~permits:5 in
    B.run rt
      (Semaphore.with_permits sem 3 (fun () ->
           E.sync (fun () -> failwith "permit body defect")))
    |> expect_die;
    Alcotest.(check int) "available 5" 5 (Semaphore.available sem)

  let test_semaphore_with_permits_releases_on_timeout () =
    B.with_test_clock @@ fun ctx clock rt ->
    let sem = Semaphore.make ~permits:3 in
    let timed_out = ref false in
    let eff =
      Semaphore.with_permits sem 2 (fun () ->
          E.delay (Duration.ms 100) E.unit)
      |> E.timeout (Duration.ms 10)
      |> E.bind_error (fun (`Timeout : [ `Timeout ]) ->
           E.sync (fun () -> timed_out := true))
    in
    let promise = B.fork_run ctx rt eff in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 10);
    check_exit_ok Alcotest.unit "timed out" () (B.await promise);
    Alcotest.(check bool) "timed_out" true !timed_out;
    Alcotest.(check int) "released" 3 (Semaphore.available sem)

  let test_semaphore_cancellation_stress () =
    B.with_test_clock @@ fun ctx clock rt ->
    let sem = Semaphore.make ~permits:8 in
    let holder =
      Semaphore.with_permits sem 1 (fun () ->
          E.delay (Duration.ms 10_000) E.unit)
    in
    let holders = List.init 8 (fun _ -> B.fork_run ctx rt holder) in
    wait_for_sleepers clock 8;
    Alcotest.(check int) "available 0" 0 (Semaphore.available sem);
    let waiters =
      List.init 50 (fun _ ->
          B.fork_run ctx rt
            (Semaphore.acquire sem 1
             |> E.timeout (Duration.ms 5)
             |> E.bind_error (fun (`Timeout : [ `Timeout ]) -> E.pure ())))
    in
    wait_for_sleepers clock 58;
    B.adjust_clock clock (Duration.ms 5);
    List.iter
      (fun p -> check_exit_ok Alcotest.unit "cancelled" () (B.await p))
      waiters;
    Alcotest.(check int) "cancelled waiters" 50
      (Semaphore.cancelled_waiters sem);
    Alcotest.(check int) "waiting 0" 0 (Semaphore.waiting sem);
    B.adjust_clock clock (Duration.ms 10_000);
    List.iter
      (fun p -> check_exit_ok Alcotest.unit "holder" () (B.await p))
      holders;
    Alcotest.(check int) "final available" 8 (Semaphore.available sem)

  let test_semaphore_cancellation_removes_waiters_behind_active_waiter () =
    B.with_test_clock @@ fun ctx clock rt ->
    let sem = Semaphore.make ~permits:2 in
    ignore (run_ok rt (Semaphore.acquire sem 2) : unit);
    let blocked =
      B.fork_run ctx rt
        (Semaphore.acquire sem 2
         |> E.bind (fun () -> E.sync (fun () -> Semaphore.release sem 2)))
    in
    wait_until (fun () -> Semaphore.waiting sem = 1);
    let cancelled =
      List.init 10 (fun _ ->
          B.fork_run ctx rt
            (Semaphore.acquire sem 1
             |> E.timeout (Duration.ms 5)
             |> E.bind_error (fun (`Timeout : [ `Timeout ]) -> E.pure ())))
    in
    wait_for_sleepers clock 10;
    B.adjust_clock clock (Duration.ms 5);
    List.iter
      (fun p -> check_exit_ok Alcotest.unit "cancelled" () (B.await p))
      cancelled;
    Alcotest.(check int) "only active waiter remains" 1 (Semaphore.waiting sem);
    Semaphore.release sem 2;
    check_exit_ok Alcotest.unit "blocked waiter completes" () (B.await blocked);
    Alcotest.(check int) "permits returned" 2 (Semaphore.available sem)

  let test_semaphore_fifo_wakes_waiters_in_order () =
    B.with_runtime @@ fun ctx rt ->
    let sem = Semaphore.make ~permits:1 in
    ignore (run_ok rt (Semaphore.acquire sem 1) : unit);
    let completed = ref [] in
    let waiter name =
      Semaphore.acquire sem 1
      |> E.bind (fun () ->
             E.sync (fun () -> completed := name :: !completed))
    in
    let first = B.fork_run ctx rt (waiter "first") in
    wait_until (fun () -> Semaphore.waiting sem = 1);
    let second = B.fork_run ctx rt (waiter "second") in
    wait_until (fun () -> Semaphore.waiting sem = 2);
    Semaphore.release sem 1;
    check_exit_ok Alcotest.unit "first woke" () (B.await first);
    Alcotest.(check (list string)) "first only" [ "first" ] !completed;
    Semaphore.release sem 1;
    check_exit_ok Alcotest.unit "second woke" () (B.await second);
    Alcotest.(check (list string)) "fifo order" [ "second"; "first" ] !completed

  let test_semaphore_waiting_ignores_resolved_waiter () =
    B.with_runtime @@ fun ctx rt ->
    let sem = Semaphore.make ~permits:1 in
    ignore (run_ok rt (Semaphore.acquire sem 1) : unit);
    let waiter = B.fork_run ctx rt (Semaphore.acquire sem 1) in
    wait_until (fun () -> Semaphore.waiting sem = 1);
    Semaphore.release sem 1;
    Alcotest.(check int) "resolved waiter no longer waiting" 0
      (Semaphore.waiting sem);
    check_exit_ok Alcotest.unit "waiter acquired" () (B.await waiter);
    Semaphore.release sem 1

  let test_semaphore_multi_permit_contention () =
    B.with_test_clock @@ fun ctx clock rt ->
    let sem = Semaphore.make ~permits:5 in
    let hold n duration =
      Semaphore.acquire sem n
      |> E.bind (fun () ->
             E.delay (Duration.ms duration) E.unit
             |> E.bind (fun () -> E.sync (fun () -> Semaphore.release sem n)))
    in
    let h1 = B.fork_run ctx rt (hold 2 50) in
    let h2 = B.fork_run ctx rt (hold 2 100) in
    wait_for_sleepers clock 2;
    Alcotest.(check int) "available 1" 1 (Semaphore.available sem);
    let waiter =
      B.fork_run ctx rt
        (Semaphore.acquire sem 3
         |> E.bind (fun () ->
                E.sync (fun () -> Semaphore.release sem 3)
                |> E.map (fun () -> "got3")))
    in
    B.yield ();
    Alcotest.(check int) "waiting 1" 1 (Semaphore.waiting sem);
    B.adjust_clock clock (Duration.ms 50);
    check_exit_ok Alcotest.unit "h1" () (B.await h1);
    check_exit_ok Alcotest.string "waiter got 3" "got3" (B.await waiter);
    Alcotest.(check int) "available 3 after waiter" 3
      (Semaphore.available sem);
    B.adjust_clock clock (Duration.ms 50);
    check_exit_ok Alcotest.unit "h2" () (B.await h2);
    Alcotest.(check int) "final available" 5 (Semaphore.available sem)

  let test_semaphore_with_permits_or_abort_acquires_when_available () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let sem = Semaphore.make ~permits:1 in
    let abort = E.delay (Duration.ms 1_000_000) E.unit in
    let observed =
      run_ok rt
        (Semaphore.with_permits_or_abort sem 1 ~abort (fun () ->
             E.sync (fun () -> Semaphore.available sem)))
    in
    (match observed with
    | Some available ->
        Alcotest.(check int) "permit held in body" 0 available
    | None -> Alcotest.fail "expected permit body to run");
    Alcotest.(check int) "permit released after body" 1 (Semaphore.available sem)

  let test_semaphore_with_permits_or_abort_aborts_without_permit () =
    B.with_test_clock @@ fun ctx clock rt ->
    let sem = Semaphore.make ~permits:1 in
    ignore (run_ok rt (Semaphore.acquire sem 1) : unit);
    let abort = E.delay (Duration.ms 5) E.unit in
    let result =
      B.fork_run ctx rt
        (Semaphore.with_permits_or_abort sem 1 ~abort (fun () -> E.unit))
    in
    wait_until (fun () -> Semaphore.waiting sem = 1);
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    (match B.await result with
    | Exit.Ok None -> ()
    | Exit.Ok (Some ()) -> Alcotest.fail "expected abort to win"
    | Exit.Error cause ->
        Alcotest.failf "unexpected error: %a" (Cause.pp pp_hidden) cause);
    Alcotest.(check int) "no waiter left" 0 (Semaphore.waiting sem);
    Alcotest.(check int) "no permit consumed by aborted acquire" 0
      (Semaphore.available sem)

  let test_semaphore_with_permits_or_abort_reclaims_unclaimed_permit_on_abort () =
    B.with_runtime @@ fun ctx rt ->
    let sem = Semaphore.make ~permits:1 in
    ignore (run_ok rt (Semaphore.acquire sem 1) : unit);
    let abort, abort_resolver = B.create_promise () in
    let result =
      B.fork_run ctx rt
        (Semaphore.with_permits_or_abort sem 1
           ~abort:(B.await_effect abort)
           (fun () -> E.unit))
    in
    wait_until (fun () -> Semaphore.waiting sem = 1);
    B.resolve abort_resolver ();
    Semaphore.release sem 1;
    (match B.await result with
    | Exit.Ok None -> ()
    | Exit.Ok (Some ()) -> Alcotest.fail "expected abort to win"
    | Exit.Error cause ->
        Alcotest.failf "unexpected error: %a" (Cause.pp pp_hidden) cause);
    Alcotest.(check int) "permit reclaimed, none leaked" 1
      (Semaphore.available sem)

  let test_semaphore_with_permits_or_abort_releases_on_outer_cancel () =
    B.with_runtime @@ fun _ctx rt ->
    let sem = Semaphore.make ~permits:1 in
    let never, _never_resolver = B.create_promise () in
    let never_effect = B.await_effect never in
    let observe_claim =
      wait_until_effect (fun () -> Semaphore.available sem = 0)
      |> E.map (fun () -> `Observed_claim)
    in
    let acquire =
      Semaphore.with_permits_or_abort sem 1 ~abort:never_effect (fun () ->
          never_effect)
      |> E.map (function Some () -> `Acquired | None -> `Aborted)
    in
    (match B.run rt (E.race [ observe_claim; acquire ]) with
    | Exit.Ok `Observed_claim -> ()
    | Exit.Ok `Acquired -> Alcotest.fail "acquire branch unexpectedly won"
    | Exit.Ok `Aborted -> Alcotest.fail "abort branch unexpectedly won"
    | Exit.Error cause ->
        Alcotest.failf "unexpected error: %a" (Cause.pp pp_hidden) cause);
    Alcotest.(check int) "discarded claimed permit released" 1
      (Semaphore.available sem)

  let test_semaphore_cancel_after_wakeup_returns_permit () =
    B.with_runtime @@ fun ctx rt ->
    let sem = Semaphore.make ~permits:1 in
    ignore (run_ok rt (Semaphore.acquire sem 1) : unit);
    let waiter = B.fork_run_cancelable ctx rt (Semaphore.acquire sem 1) in
    wait_until (fun () -> Semaphore.waiting sem = 1);
    B.cancel_fiber waiter;
    Semaphore.release sem 1;
    expect_cancelled "waiter" (B.await_cancelable waiter);
    Alcotest.(check int) "permit returned" 1 (Semaphore.available sem);
    Alcotest.(check int) "cancelled waiter" 1 (Semaphore.cancelled_waiters sem)

  let test_pubsub_unbounded_broadcasts_to_current_subscribers () =
    B.with_runtime @@ fun _ctx rt ->
    let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
    let program =
      let open Eta.Syntax in
      Pubsub.subscribe hub @@ fun a ->
      Pubsub.subscribe hub @@ fun b ->
      let* r1 = Pubsub.publish hub 10 in
      let* r2 = Pubsub.publish hub 20 in
      let* a1 = Pubsub.recv a in
      let* a2 = Pubsub.recv a in
      let* b1 = Pubsub.recv b in
      let* b2 = Pubsub.recv b in
      E.pure (r1, r2, [ a1; a2 ], [ b1; b2 ])
    in
    let r1, r2, a_values, b_values = run_ok rt program in
    Alcotest.check publish_result "publish 1"
      { Pubsub.subscriber_count = 2; dropped = 0 }
      r1;
    Alcotest.check publish_result "publish 2"
      { Pubsub.subscriber_count = 2; dropped = 0 }
      r2;
    Alcotest.(check (list int)) "subscriber a" [ 10; 20 ] a_values;
    Alcotest.(check (list int)) "subscriber b" [ 10; 20 ] b_values

  let test_pubsub_one_publisher_one_subscriber_preserves_order () =
    B.with_runtime @@ fun _ctx rt ->
    let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
    let program =
      let open Eta.Syntax in
      Pubsub.subscribe hub @@ fun sub ->
      let* r1 = Pubsub.publish hub 1 in
      let* r2 = Pubsub.publish hub 2 in
      let* r3 = Pubsub.publish hub 3 in
      let* first = Pubsub.recv sub in
      let* second = Pubsub.recv sub in
      let* third = Pubsub.recv sub in
      E.pure ([ r1; r2; r3 ], [ first; second; third ])
    in
    let publish_results, received = run_ok rt program in
    List.iteri
      (fun i result ->
        Alcotest.check publish_result
          ("publish " ^ string_of_int (i + 1))
          { Pubsub.subscriber_count = 1; dropped = 0 }
          result)
      publish_results;
    Alcotest.(check (list int)) "received order" [ 1; 2; 3 ] received

  let test_pubsub_publish_without_subscribers_does_not_retain_messages () =
    B.with_runtime @@ fun _ctx rt ->
    let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
    let program =
      let open Eta.Syntax in
      let* r1 = Pubsub.publish hub 10 in
      let* r2 = Pubsub.publish hub 20 in
      Pubsub.subscribe hub @@ fun sub ->
      let* after_subscribe = Pubsub.try_recv sub in
      E.pure (r1, r2, after_subscribe)
    in
    let r1, r2, after_subscribe = run_ok rt program in
    Alcotest.check publish_result "first no subscribers"
      { Pubsub.subscriber_count = 0; dropped = 0 }
      r1;
    Alcotest.check publish_result "second no subscribers"
      { Pubsub.subscriber_count = 0; dropped = 0 }
      r2;
    Alcotest.check recv_result "late subscriber has no backlog" `Empty
      after_subscribe

  let test_pubsub_late_subscriber_only_receives_later_messages () =
    B.with_runtime @@ fun _ctx rt ->
    let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
    let program =
      let open Eta.Syntax in
      Pubsub.subscribe hub @@ fun early ->
      let* _ = Pubsub.publish hub 1 in
      Pubsub.subscribe hub @@ fun late ->
      let* _ = Pubsub.publish hub 2 in
      let* early_first = Pubsub.recv early in
      let* early_second = Pubsub.recv early in
      let* late_first = Pubsub.recv late in
      let* late_after = Pubsub.try_recv late in
      E.pure (early_first, early_second, late_first, late_after)
    in
    let early_first, early_second, late_first, late_after = run_ok rt program in
    Alcotest.(check int) "early first" 1 early_first;
    Alcotest.(check int) "early second" 2 early_second;
    Alcotest.(check int) "late first" 2 late_first;
    Alcotest.check recv_result "late did not receive old message" `Empty
      late_after

  let test_pubsub_many_publishers_many_subscribers_preserve_message_sets () =
    B.with_runtime @@ fun _ctx rt ->
    let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
    let program =
      let open Eta.Syntax in
      Pubsub.subscribe hub @@ fun a ->
      Pubsub.subscribe hub @@ fun b ->
      let publish_many publisher =
        E.map_par (fun n ->
            Pubsub.publish hub (publisher, n) |> E.map (fun _ -> ())) [ 1; 2; 3 ]
        |> E.map (fun _ -> ())
      in
      let* (), () = E.par (publish_many "left") (publish_many "right") in
      let* a_values = E.all (List.init 6 (fun _ -> Pubsub.recv a)) in
      let* b_values = E.all (List.init 6 (fun _ -> Pubsub.recv b)) in
      E.pure (a_values, b_values)
    in
    let sort_values =
      List.sort (fun (p1, n1) (p2, n2) ->
          match String.compare p1 p2 with 0 -> Int.compare n1 n2 | c -> c)
    in
    let expected =
      sort_values
        [
          ("left", 1);
          ("left", 2);
          ("left", 3);
          ("right", 1);
          ("right", 2);
          ("right", 3);
        ]
    in
    let a_values, b_values = run_ok rt program in
    Alcotest.(check (list (pair string int))) "subscriber a message set"
      expected (sort_values a_values);
    Alcotest.(check (list (pair string int))) "subscriber b message set"
      expected (sort_values b_values)

  let test_pubsub_drop_new_uses_global_capacity () =
    B.with_runtime @@ fun _ctx rt ->
    let hub = Pubsub.create ~overflow:(Pubsub.Drop_new { capacity = 1 }) () in
    let program =
      let open Eta.Syntax in
      Pubsub.subscribe hub @@ fun a ->
      Pubsub.subscribe hub @@ fun b ->
      let* r1 = Pubsub.publish hub 1 in
      let* r2 = Pubsub.publish hub 2 in
      let* first_a = Pubsub.recv a in
      let* r3 = Pubsub.publish hub 3 in
      let* first_b = Pubsub.recv b in
      let* r4 = Pubsub.publish hub 4 in
      let* second_a = Pubsub.recv a in
      let* second_b = Pubsub.recv b in
      E.pure (r1, r2, first_a, r3, first_b, r4, second_a, second_b)
    in
    let r1, r2, first_a, r3, first_b, r4, second_a, second_b =
      run_ok rt program
    in
    Alcotest.check publish_result "first accepted"
      { Pubsub.subscriber_count = 2; dropped = 0 }
      r1;
    Alcotest.check publish_result "second dropped"
      { Pubsub.subscriber_count = 2; dropped = 2 }
      r2;
    Alcotest.(check int) "a first" 1 first_a;
    Alcotest.check publish_result "third still dropped while b lags"
      { Pubsub.subscriber_count = 2; dropped = 2 }
      r3;
    Alcotest.(check int) "b first" 1 first_b;
    Alcotest.check publish_result "fourth accepted after drain"
      { Pubsub.subscriber_count = 2; dropped = 0 }
      r4;
    Alcotest.(check int) "a second" 4 second_a;
    Alcotest.(check int) "b second" 4 second_b

  let test_pubsub_backpressure_canceled_publish_is_atomic () =
    B.with_runtime @@ fun _ctx rt ->
    let hub = Pubsub.create ~overflow:(Pubsub.Backpressure { capacity = 1 }) () in
    let ready = Queue.unbounded () in
    let program =
      let open Eta.Syntax in
      Pubsub.subscribe hub @@ fun a ->
      Pubsub.subscribe hub @@ fun b ->
      let* _ = Pubsub.publish hub 1 in
      let* first_a = Pubsub.recv a in
      let blocked_publisher =
        let* () = Queue.send ready () in
        Pubsub.publish hub 2 |> E.map (fun _ -> `Published)
      in
      let cancel_after_blocked =
        let* () = Queue.take ready in
        let* () = wait_for_waiting_publisher hub in
        E.pure `Canceled
      in
      let* race_result = E.race [ blocked_publisher; cancel_after_blocked ] in
      let* () = wait_for_cancelled_publisher hub in
      let* after_a = Pubsub.try_recv a in
      let* first_b = Pubsub.recv b in
      let* r3 = Pubsub.publish hub 3 in
      let* second_a = Pubsub.recv a in
      let* second_b = Pubsub.recv b in
      E.pure (race_result, first_a, after_a, first_b, r3, second_a, second_b)
    in
    let race_result, first_a, after_a, first_b, r3, second_a, second_b =
      run_ok rt program
    in
    Alcotest.(
      check
        (testable
           (fun fmt -> function
             | `Published -> Format.pp_print_string fmt "`Published"
             | `Canceled -> Format.pp_print_string fmt "`Canceled")
           ( = )))
      "blocked publisher canceled" `Canceled race_result;
    Alcotest.(check int) "a first" 1 first_a;
    Alcotest.check recv_result "a did not receive canceled publish" `Empty
      after_a;
    Alcotest.(check int) "b first" 1 first_b;
    Alcotest.check publish_result "publish after cancellation"
      { Pubsub.subscriber_count = 2; dropped = 0 }
      r3;
    Alcotest.(check int) "a next skips canceled publish" 3 second_a;
    Alcotest.(check int) "b next skips canceled publish" 3 second_b

  let test_pubsub_backpressure_waits_for_lagging_subscriber () =
    B.with_runtime @@ fun _ctx rt ->
    let hub = Pubsub.create ~overflow:(Pubsub.Backpressure { capacity = 1 }) () in
    let program =
      let open Eta.Syntax in
      Pubsub.subscribe hub @@ fun a ->
      Pubsub.subscribe hub @@ fun b ->
      let* _ = Pubsub.publish hub 1 in
      let* first_a = Pubsub.recv a in
      let second_completed = ref false in
      let publisher =
        let* r2 = Pubsub.publish hub 2 in
        let* () = E.sync (fun () -> second_completed := true) in
        E.pure r2
      in
      let observer =
        let* () = wait_for_waiting_publisher hub in
        let before_b_receives = !second_completed in
        let* first_b = Pubsub.recv b in
        let* second_a = Pubsub.recv a in
        let* second_b = Pubsub.recv b in
        E.pure (before_b_receives, first_b, second_a, second_b)
      in
      let* r2, observed = E.par publisher observer in
      E.pure (first_a, r2, observed, !second_completed)
    in
    let first_a, r2, (before_b_receives, first_b, second_a, second_b), after =
      run_ok rt program
    in
    Alcotest.(check int) "a first" 1 first_a;
    Alcotest.(check bool) "second publish waited for b" false before_b_receives;
    Alcotest.(check int) "b first" 1 first_b;
    Alcotest.check publish_result "second publish result"
      { Pubsub.subscriber_count = 2; dropped = 0 }
      r2;
    Alcotest.(check int) "a second" 2 second_a;
    Alcotest.(check int) "b second" 2 second_b;
    Alcotest.(check bool) "second publish completed" true after

  let test_pubsub_close_wakes_blocked_backpressure_publisher () =
    B.with_runtime @@ fun _ctx rt ->
    let hub = Pubsub.create ~overflow:(Pubsub.Backpressure { capacity = 1 }) () in
    let program =
      let open Eta.Syntax in
      Pubsub.subscribe hub @@ fun _sub ->
      let* _ = Pubsub.publish hub 1 in
      let blocked_publisher =
        Pubsub.publish hub 2
        |> E.map (fun _ -> `Published)
        |> E.bind_error (function
             | `Closed -> E.pure `Closed
             | `Closed_with_error err -> E.pure (`Closed_with_error err))
      in
      let closer =
        let* () = wait_for_waiting_publisher hub in
        E.sync (fun () -> Pubsub.close hub)
      in
      E.par blocked_publisher closer |> E.map fst
    in
    (match run_ok rt program with
    | `Closed -> ()
    | `Published -> Alcotest.fail "blocked publisher unexpectedly published"
    | `Closed_with_error err ->
        Alcotest.failf "unexpected close error %s" err)

  let test_pubsub_close_wakes_blocked_subscriber () =
    B.with_runtime @@ fun _ctx rt ->
    let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
    let program =
      let open Eta.Syntax in
      Pubsub.subscribe hub @@ fun sub ->
      let blocked =
        Pubsub.recv sub
        |> E.map (fun _ -> `Received)
        |> E.bind_error (function
             | `Closed -> E.pure `Closed
             | `Closed_with_error err -> E.pure (`Closed_with_error err))
      in
      let closer =
        let* () =
          wait_until_effect (fun () ->
              (Pubsub.stats hub).Pubsub.waiting_receivers = 1)
        in
        E.sync (fun () -> Pubsub.close hub)
      in
      E.par blocked closer |> E.map fst
    in
    (match run_ok rt program with
    | `Closed -> ()
    | `Received -> Alcotest.fail "blocked subscriber unexpectedly received"
    | `Closed_with_error err ->
        Alcotest.failf "unexpected close error %s" err)

  let test_pubsub_close_with_error_drains_buffer () =
    B.with_runtime @@ fun _ctx rt ->
    let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
    let program =
      let open Eta.Syntax in
      Pubsub.subscribe hub @@ fun sub ->
      let* _ = Pubsub.publish hub 7 in
      let* () = E.sync (fun () -> Pubsub.close_with_error hub "boom") in
      let* first = Pubsub.recv sub in
      let* second =
        Pubsub.recv sub
        |> E.map (fun value -> `Unexpected_value value)
        |> E.bind_error (fun close -> E.pure (`Closed_as close))
      in
      E.pure (first, second)
    in
    let first, second = run_ok rt program in
    Alcotest.(check int) "buffered value" 7 first;
    Alcotest.(
      check
        (testable
           (fun fmt -> function
             | `Unexpected_value n -> Format.fprintf fmt "unexpected %d" n
             | `Closed_as close -> pp_close_result fmt close)
           ( = )))
      "typed close after drain" (`Closed_as (`Closed_with_error "boom"))
      second

  let test_pubsub_subscription_cleanup_on_body_cancellation () =
    B.with_runtime @@ fun _ctx rt ->
    let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
    let leaked = ref None in
    let ready = Queue.unbounded () in
    let never = Queue.unbounded () in
    let program =
      let open Eta.Syntax in
      let body =
        Pubsub.subscribe hub @@ fun sub ->
        let* () = E.sync (fun () -> leaked := Some sub) in
        let* () = Queue.send ready () in
        Queue.take never
      in
      let cancel_after_acquire =
        let* () = Queue.take ready in
        E.pure ()
      in
      E.race [ body; cancel_after_acquire ]
    in
    ignore (run_ok rt program : unit);
    Alcotest.(check int) "subscriber removed" 0 (Pubsub.stats hub).subscribers;
    match !leaked with
    | None -> Alcotest.fail "expected leaked subscription from fixture"
    | Some sub -> expect_closed rt (Pubsub.recv sub)

  let test_pubsub_timeout_blocked_recv_cleans_waiter () =
    B.with_test_clock @@ fun ctx clock rt ->
    let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
    let program =
      Pubsub.subscribe hub @@ fun sub ->
      Pubsub.recv sub
      |> E.timeout_as (Duration.ms 5) ~on_timeout:`Timeout
      |> E.bind_error (function
           | `Timeout ->
               E.sync (fun () ->
                   let stats = Pubsub.stats hub in
                   (stats.waiting_receivers, stats.cancelled_receivers))
           | `Closed -> E.sync (fun () -> Alcotest.fail "unexpected close")
           | `Closed_with_error _ ->
               E.sync (fun () -> Alcotest.fail "unexpected close_with_error"))
    in
    let promise = B.fork_run ctx rt program in
    wait_until (fun () -> (Pubsub.stats hub).Pubsub.waiting_receivers = 1);
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    check_exit_ok
      Alcotest.(pair int int)
      "waiter counters" (0, 1) (B.await promise)

  let test_pubsub_cancelled_blocked_publishers_release_payloads () =
    B.with_runtime @@ fun ctx rt ->
    let hub = Pubsub.create ~overflow:(Pubsub.Backpressure { capacity = 1 }) () in
    let ready = Queue.unbounded () in
    let never = Queue.unbounded () in
    let holder = ref None in
    let body =
      let open Eta.Syntax in
      Pubsub.subscribe hub @@ fun sub ->
      let* () = E.sync (fun () -> holder := Some sub) in
      let* () = Queue.send ready () in
      Queue.take never
    in
    let body_fiber = B.fork_run ctx rt body in
    ignore (run_ok rt (Queue.take ready) : unit);
    ignore
      (run_ok rt (Pubsub.publish hub (Bytes.create 1))
        : Pubsub.publish_result);
    Gc.full_major ();
    let base_words = (Gc.stat ()).Gc.live_words in
    for _ = 1 to 32 do
      let publisher =
        B.fork_run_cancelable ctx rt
          (Pubsub.publish hub (Bytes.make (1024 * 1024) 'x'))
      in
      wait_until (fun () -> (Pubsub.stats hub).Pubsub.waiting_publishers = 1);
      B.cancel_fiber publisher;
      expect_cancelled "publisher" (B.await_cancelable publisher)
    done;
    let retained = retained_bytes_since base_words in
    Alcotest.(check bool)
      "cancelled publisher payloads released" true
      (retained < (4 * 1024 * 1024));
    Queue.close never;
    ignore (B.await body_fiber : (unit, [> `Closed ]) Exit.t)

  let test_pubsub_cancel_blocked_recv_cleans_waiter () =
    B.with_runtime @@ fun ctx rt ->
    let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
    let ready = Queue.unbounded () in
    let never = Queue.unbounded () in
    let holder = ref None in
    let body =
      let open Eta.Syntax in
      Pubsub.subscribe hub @@ fun sub ->
      let* () = E.sync (fun () -> holder := Some sub) in
      let* () = Queue.send ready () in
      Queue.take never
    in
    let body_fiber = B.fork_run ctx rt body in
    ignore (run_ok rt (Queue.take ready) : unit);
    let sub =
      match !holder with
      | Some sub -> sub
      | None -> Alcotest.fail "subscription was not captured"
    in
    let receiver = B.fork_run_cancelable ctx rt (Pubsub.recv sub) in
    wait_until (fun () -> (Pubsub.stats hub).waiting_receivers = 1);
    B.cancel_fiber receiver;
    expect_cancelled "receiver" (B.await_cancelable receiver);
    Alcotest.(check int)
      "waiting receivers" 0 (Pubsub.stats hub).waiting_receivers;
    Alcotest.(check int)
      "cancelled receivers" 1 (Pubsub.stats hub).cancelled_receivers;
    ignore (run_ok rt (Pubsub.publish hub 42) : Pubsub.publish_result);
    Alcotest.(check int) "next recv gets published value" 42
      (run_ok rt (Pubsub.recv sub));
    Queue.close never;
    ignore (B.await body_fiber : (unit, [> `Closed ]) Exit.t)

  let test_pubsub_invalid_capacity_rejected () =
    Alcotest.check_raises "drop_new zero capacity"
      (Invalid_argument "Eta.Pubsub.create: bounded capacity must be > 0")
      (fun () ->
        ignore (Pubsub.create ~overflow:(Pubsub.Drop_new { capacity = 0 }) ()));
    Alcotest.check_raises "backpressure zero capacity"
      (Invalid_argument "Eta.Pubsub.create: bounded capacity must be > 0")
      (fun () ->
        ignore
          (Pubsub.create ~overflow:(Pubsub.Backpressure { capacity = 0 }) ()))

  let tests =
    Effect_suites.tests
    @ [
      ( "MutableRef",
        [
          Alcotest.test_case "make get" `Quick test_mutable_ref_make_get;
          Alcotest.test_case "set" `Quick test_mutable_ref_set;
          Alcotest.test_case "update" `Quick test_mutable_ref_update;
          Alcotest.test_case "update_and_get" `Quick
            test_mutable_ref_update_and_get;
          Alcotest.test_case "get_and_set" `Quick test_mutable_ref_get_and_set;
          Alcotest.test_case "compare_and_set" `Quick
            test_mutable_ref_compare_and_set;
          Alcotest.test_case "concurrent update" `Quick
            test_mutable_ref_concurrent_update;
          Alcotest.test_case "incr decr" `Quick test_mutable_ref_incr_decr;
        ] );
      ( "Queue",
        [
          Alcotest.test_case "send recv close" `Quick
            test_queue_send_recv_close;
          Alcotest.test_case "close fence" `Quick test_queue_close_fence;
          Alcotest.test_case "close with error drains" `Quick
            test_queue_close_with_error_drains;
          Alcotest.test_case "timeout blocked take cleans waiter" `Quick
            test_queue_timeout_blocked_recv_cleans_waiter;
          Alcotest.test_case "cancel blocked take" `Quick
            test_queue_cancel_blocked_recv_cleans_waiter;
          Alcotest.test_case "offer unbounded constructor" `Quick
            test_queue_offer_unbounded_create_and_alias;
          Alcotest.test_case "named constructors and views" `Quick
            test_queue_named_constructors_and_views;
          Alcotest.test_case "sliding keeps latest capacity" `Quick
            test_queue_sliding_keeps_latest_capacity;
          Alcotest.test_case "logical size tracks waiters" `Quick
            test_queue_logical_size_tracks_waiters;
          Alcotest.test_case "shutdown is immediate" `Quick
            test_queue_shutdown_is_immediate;
          Alcotest.test_case "drop new reports admission result" `Quick
            test_queue_drop_new_reports_admission_result;
          Alcotest.test_case "send drop_new fails on rejection" `Quick
            test_queue_send_drop_new_fails_on_rejection;
          Alcotest.test_case "backpressure offer waits for capacity" `Quick
            test_queue_backpressure_offer_waits_for_capacity;
          Alcotest.test_case "backpressure try_offer reports full" `Quick
            test_queue_backpressure_try_send_reports_full;
          Alcotest.test_case "backpressure cancel blocked offer" `Quick
            test_queue_backpressure_cancel_blocked_offer;
          Alcotest.test_case "close wakes blocked offer" `Quick
            test_queue_close_wakes_blocked_offer;
          Alcotest.test_case "offer closed failures" `Quick
            test_queue_offer_closed_failures;
          Alcotest.test_case "close_with_error wakes blocked offer" `Quick
            test_queue_close_with_error_wakes_blocked_offer;
          Alcotest.test_case "take_all and take_up_to drain" `Quick
            test_queue_take_all_and_batch_drain;
          Alcotest.test_case "take_all opens backpressure capacity" `Quick
            test_queue_take_all_opens_backpressure_capacity;
          Alcotest.test_case "bounded capacity rejects non-positive" `Quick
            test_queue_bounded_capacity_rejects_non_positive;
        ] );
      ( "Channel",
        [
          Alcotest.test_case "try send recv" `Quick
            test_channel_try_send_try_recv;
          Alcotest.test_case "fifo send recv" `Quick
            test_channel_fifo_send_recv;
          Alcotest.test_case "blocking send backpressure" `Quick
            test_channel_blocking_send_backpressure;
          Alcotest.test_case "blocked sender not passed" `Quick
            test_channel_blocked_sender_is_not_passed_by_later_sender;
          Alcotest.test_case "blocking recv" `Quick test_channel_blocking_recv;
          Alcotest.test_case "close wakes blocked users" `Quick
            test_channel_close_wakes_blocked_senders_and_receivers;
          Alcotest.test_case "close with error drains" `Quick
            test_channel_close_with_error_drains_buffer;
          Alcotest.test_case "close drains buffer then reports closed" `Quick
            test_channel_close_drains_buffer_then_reports_closed;
          Alcotest.test_case "timeout blocked send cleans waiter" `Quick
            test_channel_timeout_blocked_send_cleans_waiter;
          Alcotest.test_case "timeout blocked recv cleans waiter" `Quick
            test_channel_timeout_blocked_recv_cleans_waiter;
          Alcotest.test_case "cancel blocked send" `Quick
            test_channel_cancel_blocked_send_cleans_waiter;
          Alcotest.test_case "cancel blocked send releases payload" `Quick
            test_channel_cancelled_blocked_senders_release_payloads;
          Alcotest.test_case "cancel blocked recv" `Quick
            test_channel_cancel_blocked_recv_cleans_waiter;
        ] );
      ( "Pubsub",
        [
          Alcotest.test_case "unbounded broadcasts" `Quick
            test_pubsub_unbounded_broadcasts_to_current_subscribers;
          Alcotest.test_case "one publisher one subscriber order" `Quick
            test_pubsub_one_publisher_one_subscriber_preserves_order;
          Alcotest.test_case "publish without subscribers does not retain"
            `Quick test_pubsub_publish_without_subscribers_does_not_retain_messages;
          Alcotest.test_case "late subscriber only receives later messages"
            `Quick test_pubsub_late_subscriber_only_receives_later_messages;
          Alcotest.test_case "many publishers many subscribers" `Quick
            test_pubsub_many_publishers_many_subscribers_preserve_message_sets;
          Alcotest.test_case "drop_new global capacity" `Quick
            test_pubsub_drop_new_uses_global_capacity;
          Alcotest.test_case "backpressure canceled publish atomic" `Quick
            test_pubsub_backpressure_canceled_publish_is_atomic;
          Alcotest.test_case "backpressure waits for lagging subscriber"
            `Quick test_pubsub_backpressure_waits_for_lagging_subscriber;
          Alcotest.test_case "backpressure close wakes publisher" `Quick
            test_pubsub_close_wakes_blocked_backpressure_publisher;
          Alcotest.test_case "close wakes blocked subscriber" `Quick
            test_pubsub_close_wakes_blocked_subscriber;
          Alcotest.test_case "close with error drains" `Quick
            test_pubsub_close_with_error_drains_buffer;
          Alcotest.test_case "subscription cancellation cleanup" `Quick
            test_pubsub_subscription_cleanup_on_body_cancellation;
          Alcotest.test_case "timeout blocked recv cleans waiter" `Quick
            test_pubsub_timeout_blocked_recv_cleans_waiter;
          Alcotest.test_case "backpressure canceled publish releases payload"
            `Quick
            test_pubsub_cancelled_blocked_publishers_release_payloads;
          Alcotest.test_case "cancel blocked recv" `Quick
            test_pubsub_cancel_blocked_recv_cleans_waiter;
          Alcotest.test_case "invalid capacity rejected" `Quick
            test_pubsub_invalid_capacity_rejected;
        ] );
      ( "Semaphore",
        [
          Alcotest.test_case "make and available" `Quick
            test_semaphore_make_available;
          Alcotest.test_case "make rejects zero permits" `Quick
            test_semaphore_make_rejects_zero_permits;
          Alcotest.test_case "acquire reduces available" `Quick
            test_semaphore_acquire_reduces_available;
          Alcotest.test_case "release increases available" `Quick
            test_semaphore_release_increases_available;
          Alcotest.test_case "release rejects negative count" `Quick
            test_semaphore_release_rejects_negative_count;
          Alcotest.test_case "release rejects zero count" `Quick
            test_semaphore_release_rejects_zero_count;
          Alcotest.test_case "release rejects over capacity" `Quick
            test_semaphore_release_rejects_over_capacity;
          Alcotest.test_case "rejects over-capacity acquire" `Quick
            test_semaphore_rejects_over_capacity_acquire;
          Alcotest.test_case "rejects over-capacity try_acquire" `Quick
            test_semaphore_rejects_over_capacity_try_acquire;
          Alcotest.test_case "acquire at capacity succeeds" `Quick
            test_semaphore_acquire_at_capacity_succeeds;
          Alcotest.test_case "try_acquire is atomic" `Quick
            test_semaphore_try_acquire_is_atomic;
          Alcotest.test_case "try_acquire does not barge queued waiter" `Quick
            test_semaphore_try_acquire_does_not_barge_queued_waiter;
          Alcotest.test_case "acquire does not barge waiters" `Quick
            test_semaphore_acquire_does_not_barge_waiters;
          Alcotest.test_case "with_permits releases on success" `Quick
            test_semaphore_with_permits_releases_on_success;
          Alcotest.test_case "with_permits releases on failure" `Quick
            test_semaphore_with_permits_releases_on_failure;
          Alcotest.test_case "with_permits releases on defect" `Quick
            test_semaphore_with_permits_releases_on_defect;
          Alcotest.test_case "with_permits releases on timeout" `Quick
            test_semaphore_with_permits_releases_on_timeout;
          Alcotest.test_case "cancellation stress" `Quick
            test_semaphore_cancellation_stress;
          Alcotest.test_case
            "cancellation removes waiters behind active waiter" `Quick
            test_semaphore_cancellation_removes_waiters_behind_active_waiter;
          Alcotest.test_case "fifo wakes waiters in order" `Quick
            test_semaphore_fifo_wakes_waiters_in_order;
          Alcotest.test_case "waiting ignores resolved waiter" `Quick
            test_semaphore_waiting_ignores_resolved_waiter;
          Alcotest.test_case "multi-permit contention" `Quick
            test_semaphore_multi_permit_contention;
          Alcotest.test_case
            "with_permits_or_abort acquires when available" `Quick
            test_semaphore_with_permits_or_abort_acquires_when_available;
          Alcotest.test_case "with_permits_or_abort aborts without permit" `Quick
            test_semaphore_with_permits_or_abort_aborts_without_permit;
          Alcotest.test_case
            "with_permits_or_abort reclaims permit after abort" `Quick
            test_semaphore_with_permits_or_abort_reclaims_unclaimed_permit_on_abort;
          Alcotest.test_case "with_permits_or_abort releases on outer cancel"
            `Quick
            test_semaphore_with_permits_or_abort_releases_on_outer_cancel;
          Alcotest.test_case "cancel after wakeup returns permit" `Quick
            test_semaphore_cancel_after_wakeup_returns_permit;
        ] );
    ]
     @ Duration_schedule_common_suites.tests
     @ Cause_exit_common_suites.tests
     @ Cause_render_common_suites.tests
     @ Logger_common_suites.tests
     @ Effect_retry_repeat_suites.tests
     @ Effect_resource_timeout_suites.tests
     @ Effect_uninterruptible_suites.tests
    @ String_helpers_common_suites.tests
     @ Log_level_common_suites.tests
     @ Runtime_contract_common_suites.tests
     @ Portable_queue_common_suites.tests
     @ Observability_suites.tests
     @ Properties_suites.tests
     @ Stress_suites.tests
     @ Upstream_invariants_suites.tests
     @ Pool_suites.tests
     @ Resource_suites.tests
     @ Supervisor_suites.tests
end
