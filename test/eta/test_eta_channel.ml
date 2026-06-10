open Eta
open Test_eta_support

let test_channel_cancel_receiver_after_delivery_requeues_message () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
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
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
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
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
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
  | `Closed | `Closed_with_error _ ->
      Alcotest.fail "unexpected closed channel");
  (match !cancel_ctx with
  | Some ctx -> Eio.Cancel.cancel ctx Exit
  | None -> Alcotest.fail "receiver did not publish cancellation context");
  (try
     match Eio.Promise.await_exn receiver with
     | Exit.Ok value -> Alcotest.(check int) "claimed delivery" 1 value
     | Exit.Error _ ->
         Alcotest.(check int) "requeued depth" 1 (Channel.stats ch).Channel.depth;
         Alcotest.(check int) "cancelled delivery" 1
           (run_ok rt (Channel.recv ch))
   with Eio.Cancel.Cancelled _ ->
     Alcotest.(check int) "requeued depth" 1 (Channel.stats ch).Channel.depth;
     Alcotest.(check int) "cancelled delivery" 1
       (run_ok rt (Channel.recv ch)));
  match run_ok rt (Channel.try_recv ch) with
  | `Empty -> ()
  | _ -> Alcotest.fail "second value should not have been admitted while full"
