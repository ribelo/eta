open Eta
open Eta_test
open Test_eta_support

let test_queue_send_recv_close () =
  with_runtime @@ fun rt ->
  let q = Queue.create () in
  run_ok rt (Queue.send q 1);
  run_ok rt (Queue.send q 2);
  Queue.close q;
  Alcotest.(check int) "first" 1 (run_ok rt (Queue.recv q));
  Alcotest.(check int) "second" 2 (run_ok rt (Queue.recv q));
  (match Runtime.run rt (Queue.recv q) with
  | Exit.Error (Cause.Fail `Closed) -> ()
  | _ -> Alcotest.fail "expected clean close");
  let stats = Queue.stats q in
  Alcotest.(check int) "sent" 2 stats.Queue.sent;
  Alcotest.(check int) "received" 2 stats.Queue.received

let test_queue_close_fence () =
  with_runtime @@ fun rt ->
  let q = Queue.create () in
  Queue.close q;
  (match run_ok rt (Queue.try_send q 1) with
  | `Closed -> ()
  | _ -> Alcotest.fail "expected closed send");
  (match run_ok rt (Queue.try_recv q) with
  | `Closed -> ()
  | _ -> Alcotest.fail "expected closed recv");
  Alcotest.(check int) "depth" 0 (Queue.stats q).depth

let test_queue_close_with_error_drains () =
  with_runtime @@ fun rt ->
  let q = Queue.create () in
  run_ok rt (Queue.send q "buffered");
  Queue.close_with_error q "provider failed";
  Alcotest.(check string) "buffered" "buffered" (run_ok rt (Queue.recv q));
  (match Runtime.run rt (Queue.recv q) with
  | Exit.Error (Cause.Fail (`Closed_with_error "provider failed")) -> ()
  | _ -> Alcotest.fail "expected close_with_error")

let test_queue_cancel_blocked_recv_cleans_waiter () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let q = Queue.create () in
  let cancel_ctx = ref None in
  let receiver =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Runtime.run rt (Queue.recv q))
  in
  wait_until (fun () -> (Queue.stats q).Queue.waiting_receivers = 1);
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  (match Eio.Promise.await_exn receiver with
  | Exit.Ok _ -> Alcotest.fail "expected cancellation"
  | Exit.Error _ -> ());
  let stats = Queue.stats q in
  Alcotest.(check int) "waiting receivers" 0 stats.Queue.waiting_receivers;
  Alcotest.(check int) "cancelled receivers" 1 stats.Queue.cancelled_receivers
