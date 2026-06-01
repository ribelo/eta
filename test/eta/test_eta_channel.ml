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

let test_channel_fifo_send_recv () =
  with_runtime @@ fun rt ->
  let ch = Channel.create ~capacity:3 () in
  run_ok rt (Channel.send ch 1);
  run_ok rt (Channel.send ch 2);
  run_ok rt (Channel.send ch 3);
  Alcotest.(check int) "first" 1 (run_ok rt (Channel.recv ch));
  Alcotest.(check int) "second" 2 (run_ok rt (Channel.recv ch));
  Alcotest.(check int) "third" 3 (run_ok rt (Channel.recv ch))

let test_channel_blocking_send_backpressure () =
  run_eio @@ fun stdenv ->
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
  run_eio @@ fun stdenv ->
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
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let ch = Channel.create ~capacity:1 () in
  let receiver = fork_run sw rt (Channel.recv ch) in
  wait_until (fun () -> (Channel.stats ch).Channel.waiting_receivers = 1);
  run_ok rt (Channel.send ch 7);
  check_exit_ok Alcotest.int "received" 7 (Eio.Promise.await receiver)

let test_channel_close_wakes_blocked_senders_and_receivers () =
  run_eio @@ fun stdenv ->
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

let test_channel_close_with_error_drains_buffer () =
  with_runtime @@ fun rt ->
  let ch = Channel.create ~capacity:1 () in
  run_ok rt (Channel.send ch 1);
  Channel.close_with_error ch `Boom;
  Alcotest.(check int) "buffered value" 1 (run_ok rt (Channel.recv ch));
  (match Runtime.run rt (Channel.recv ch) with
  | Exit.Error (Cause.Fail (`Closed_with_error `Boom)) -> ()
  | Exit.Ok _ -> Alcotest.fail "expected close_with_error after drain"
  | Exit.Error cause ->
      Alcotest.failf "unexpected channel close cause: %a"
        (Cause.pp (fun fmt -> function
          | `Closed -> Format.pp_print_string fmt "closed"
          | `Closed_with_error `Boom -> Format.pp_print_string fmt "boom"))
        cause);
  match run_ok rt (Channel.try_send ch 2) with
  | `Closed_with_error `Boom -> ()
  | _ -> Alcotest.fail "expected try_send to see close_with_error"

let test_channel_close_drains_buffer_then_reports_closed () =
  with_runtime @@ fun rt ->
  let ch = Channel.create ~capacity:2 () in
  run_ok rt (Channel.send ch 1);
  run_ok rt (Channel.send ch 2);
  Channel.close ch;
  Alcotest.(check int) "first buffered" 1 (run_ok rt (Channel.recv ch));
  Alcotest.(check int) "second buffered" 2 (run_ok rt (Channel.recv ch));
  (match Runtime.run rt (Channel.recv ch) with
  | Exit.Error (Cause.Fail `Closed) -> ()
  | Exit.Ok _ -> Alcotest.fail "expected closed after buffered values drain"
  | Exit.Error cause ->
      Alcotest.failf "unexpected close cause: %a"
        (Cause.pp (fun fmt -> function
          | `Closed -> Format.pp_print_string fmt "closed"
          | `Closed_with_error _ ->
              Format.pp_print_string fmt "closed_with_error"))
        cause);
  match run_ok rt (Channel.try_recv ch) with
  | `Closed -> ()
  | _ -> Alcotest.fail "expected try_recv to report closed after drain"

let test_channel_cancel_blocked_send_cleans_waiter () =
  run_eio @@ fun stdenv ->
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
  await_cancelled sender;
  let stats = Channel.stats ch in
  Alcotest.(check int) "waiting senders" 0 stats.Channel.waiting_senders;
  Alcotest.(check int) "cancelled senders" 1 stats.Channel.cancelled_senders;
  Alcotest.(check int) "depth unchanged" 1 stats.Channel.depth;
  Alcotest.(check int) "original value" 1 (run_ok rt (Channel.recv ch));
  match run_ok rt (Channel.try_recv ch) with
  | `Empty -> ()
  | _ -> Alcotest.fail "cancelled sender enqueued a value"

let test_channel_cancel_blocked_recv_cleans_waiter () =
  run_eio @@ fun stdenv ->
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
  await_cancelled receiver;
  Alcotest.(check int)
    "waiting receivers" 0 (Channel.stats ch).Channel.waiting_receivers

let test_channel_cancel_receiver_after_delivery_requeues_message () =
  run_eio @@ fun stdenv ->
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
  await_cancelled receiver;
  Alcotest.(check int)
    "waiting receivers" 0 (Channel.stats ch).Channel.waiting_receivers;
  Alcotest.(check int) "requeued depth" 1 (Channel.stats ch).Channel.depth;
  Alcotest.(check int) "next receiver gets value" 42 (run_ok rt (Channel.recv ch))

let test_channel_parent_switch_teardown_does_not_hang () =
  run_eio @@ fun stdenv ->
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

let test_channel_cancel_receiver_overflow_does_not_corrupt () =
  run_eio @@ fun stdenv ->
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
  run_ok rt (Channel.send ch 1);
  if Eio.Promise.is_resolved receiver then
    Alcotest.fail "receiver claimed delivery before cancellation window";
  (match run_ok rt (Channel.try_send ch 2) with
  | `Full -> ()
  | `Sent -> Alcotest.fail "unclaimed delivery did not occupy capacity"
  | `Closed | `Closed_with_error _ -> Alcotest.fail "unexpected closed channel");
  (match !cancel_ctx with
  | Some ctx -> Eio.Cancel.cancel ctx Exit
  | None -> Alcotest.fail "receiver did not publish cancellation context");
  (try match Eio.Promise.await_exn receiver with
  | Exit.Ok value -> Alcotest.(check int) "claimed delivery" 1 value
  | Exit.Error _ ->
      Alcotest.(check int) "requeued depth" 1 (Channel.stats ch).Channel.depth;
      Alcotest.(check int) "cancelled delivery" 1 (run_ok rt (Channel.recv ch))
   with Eio.Cancel.Cancelled _ ->
     Alcotest.(check int) "requeued depth" 1 (Channel.stats ch).Channel.depth;
     Alcotest.(check int) "cancelled delivery" 1 (run_ok rt (Channel.recv ch)));
  match run_ok rt (Channel.try_recv ch) with
  | `Empty -> ()
  | _ -> Alcotest.fail "second value should not have been admitted while full"
