open Eta
open Eta_test
open Test_eta_support

let test_channel_try_send_try_recv () =
  with_runtime @@ fun rt ->
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

let test_channel_blocking_send_backpressure () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let ch = Channel.create ~capacity:1 () in
  run_ok rt (Channel.send ch 1);
  let sender = fork_run sw rt (Channel.send ch 2) in
  wait_until (fun () -> (Channel.stats ch).Channel.waiting_senders = 1);
  Alcotest.(check int) "depth while blocked" 1 (Channel.stats ch).depth;
  Alcotest.(check int) "first recv" 1 (run_ok rt (Channel.recv ch));
  check_exit_ok Alcotest.unit "sender completed" () (Eio.Promise.await sender);
  Alcotest.(check int) "second recv" 2 (run_ok rt (Channel.recv ch))

let test_channel_blocked_sender_is_not_passed_by_later_sender () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let ch = Channel.create ~capacity:1 () in
  run_ok rt (Channel.send ch 1);
  let first_sender = fork_run sw rt (Channel.send ch 2) in
  wait_until (fun () -> (Channel.stats ch).Channel.waiting_senders = 1);
  Alcotest.(check int) "initial value" 1 (run_ok rt (Channel.recv ch));
  check_exit_ok Alcotest.unit "first sender admitted" ()
    (Eio.Promise.await first_sender);
  let later_sender = fork_run sw rt (Channel.send ch 3) in
  wait_until (fun () -> (Channel.stats ch).Channel.waiting_senders = 1);
  Alcotest.(check int) "blocked sender value" 2 (run_ok rt (Channel.recv ch));
  check_exit_ok Alcotest.unit "later sender admitted" ()
    (Eio.Promise.await later_sender);
  Alcotest.(check int) "later value" 3 (run_ok rt (Channel.recv ch))

let test_channel_blocking_recv () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let ch = Channel.create ~capacity:1 () in
  let receiver = fork_run sw rt (Channel.recv ch) in
  wait_until (fun () -> (Channel.stats ch).Channel.waiting_receivers = 1);
  run_ok rt (Channel.send ch 7);
  check_exit_ok Alcotest.int "received" 7 (Eio.Promise.await receiver)

let test_channel_close_wakes_blocked_senders_and_receivers () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let sender_ch = Channel.create ~capacity:1 () in
  run_ok rt (Channel.send sender_ch 1);
  let sender = fork_run sw rt (Channel.send sender_ch 2) in
  wait_until (fun () -> (Channel.stats sender_ch).Channel.waiting_senders = 1);
  Channel.close sender_ch;
  (match Eio.Promise.await sender with
  | Exit.Error (Cause.Fail `Closed) -> ()
  | _ -> Alcotest.fail "expected blocked sender closed");
  let receiver_ch = Channel.create ~capacity:1 () in
  let receiver = fork_run sw rt (Channel.recv receiver_ch) in
  wait_until (fun () -> (Channel.stats receiver_ch).Channel.waiting_receivers = 1);
  Channel.close receiver_ch;
  match Eio.Promise.await receiver with
  | Exit.Error (Cause.Fail `Closed) -> ()
  | _ -> Alcotest.fail "expected blocked receiver closed"

let test_channel_cancel_blocked_send_cleans_waiter () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let ch = Channel.create ~capacity:1 () in
  run_ok rt (Channel.send ch 1);
  let cancel_ctx = ref None in
  let sender =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Runtime.run rt (Channel.send ch 2))
  in
  wait_until (fun () -> (Channel.stats ch).Channel.waiting_senders = 1);
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  (match Eio.Promise.await_exn sender with
  | Exit.Ok _ -> Alcotest.fail "expected cancellation"
  | Exit.Error _ -> ());
  let stats = Channel.stats ch in
  Alcotest.(check int) "waiting senders" 0 stats.Channel.waiting_senders;
  Alcotest.(check int) "cancelled senders" 1 stats.Channel.cancelled_senders;
  Alcotest.(check int) "depth unchanged" 1 stats.Channel.depth;
  Alcotest.(check int) "original value" 1 (run_ok rt (Channel.recv ch));
  match run_ok rt (Channel.try_recv ch) with
  | `Empty -> ()
  | _ -> Alcotest.fail "cancelled sender enqueued a value"

let test_channel_cancel_blocked_recv_cleans_waiter () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let ch = Channel.create ~capacity:1 () in
  let cancel_ctx = ref None in
  let receiver =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Runtime.run rt (Channel.recv ch))
  in
  wait_until (fun () -> (Channel.stats ch).Channel.waiting_receivers = 1);
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  (match Eio.Promise.await_exn receiver with
  | Exit.Ok _ -> Alcotest.fail "expected cancellation"
  | Exit.Error _ -> ());
  Alcotest.(check int)
    "waiting receivers" 0 (Channel.stats ch).Channel.waiting_receivers

let test_channel_cancel_receiver_after_delivery_requeues_message () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let ch = Channel.create ~capacity:1 () in
  let cancel_ctx = ref None in
  let receiver =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Runtime.run rt (Channel.recv ch))
  in
  wait_until (fun () -> (Channel.stats ch).Channel.waiting_receivers = 1);
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  run_ok rt (Channel.send ch 42);
  (match Eio.Promise.await_exn receiver with
  | Exit.Ok _ -> Alcotest.fail "expected cancellation"
  | Exit.Error _ -> ());
  Alcotest.(check int)
    "waiting receivers" 0 (Channel.stats ch).Channel.waiting_receivers;
  Alcotest.(check int) "requeued depth" 1 (Channel.stats ch).Channel.depth;
  Alcotest.(check int) "next receiver gets value" 42 (run_ok rt (Channel.recv ch))

let test_channel_parent_switch_teardown_does_not_hang () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let ch = Channel.create ~capacity:1 () in
  run_ok rt (Channel.send ch 1);
  let outcome =
    try
      Eio.Switch.run @@ fun child_sw ->
      ignore
        (Eio.Fiber.fork_promise ~sw:child_sw (fun () ->
             Runtime.run rt (Channel.send ch 2)));
      wait_until (fun () -> (Channel.stats ch).Channel.waiting_senders = 1);
      Eio.Switch.fail child_sw Exit;
      `Returned
    with Exit -> `Cancelled
  in
  (match outcome with `Returned | `Cancelled -> ());
  Alcotest.(check int)
    "waiting senders" 0 (Channel.stats ch).Channel.waiting_senders
