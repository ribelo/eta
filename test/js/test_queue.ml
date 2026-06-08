open Test_support

let tests =
  [
    ("queue_sync",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let queue = Queue.create () in
       (match Runtime.run_now runtime (Queue.try_recv queue) with
       | Some (Exit.Ok `Empty) -> ()
       | _ -> fail "Queue.try_recv empty" "expected empty" |> raise);
       (match Runtime.run_now runtime (Queue.send queue 1) with
       | Some exit -> check_exit_ok_unit "Queue.send" exit
       | None -> fail "Queue.send" "expected sync exit" |> raise);
       (match Runtime.run_now runtime (Queue.recv queue) with
       | Some exit -> check_exit_ok_int "Queue.recv buffered" 1 exit
       | None -> fail "Queue.recv buffered" "expected sync exit" |> raise);
       (match Runtime.run_now runtime (Queue.send queue 2) with
       | Some exit -> check_exit_ok_unit "Queue.send before close" exit
       | None -> fail "Queue.send before close" "expected sync exit" |> raise);
       Queue.close queue;
       (match Runtime.run_now runtime (Queue.recv queue) with
       | Some exit -> check_exit_ok_int "Queue.recv drains after close" 2 exit
       | None -> fail "Queue.recv drains after close" "expected sync exit" |> raise);
       (match Runtime.run_now runtime (Queue.recv queue) with
       | Some (Exit.Error (Cause.Fail `Closed)) -> ()
       | _ -> fail "Queue.recv closed" "expected closed failure" |> raise);
       let stats = Queue.stats queue in
       check_equal_int "Queue.stats sent" 2 stats.sent;
       check_equal_int "Queue.stats received" 2 stats.received;
       check "Queue.stats closed" stats.closed;
       Js.Promise.resolve ());
    ("queue_recv_async",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let queue = Queue.create () in
       let p1 =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_int "Queue.recv waits" 41 exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime (Queue.recv queue))
       in
       (match Runtime.run_now runtime (Queue.send queue 41) with
       | Some exit -> check_exit_ok_unit "Queue.send wakes receiver" exit
       | None -> fail "Queue.send wakes receiver" "expected sync exit" |> raise);
       p1);
    ("queue_recv_cancel",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let queue = Queue.create () in
       let p1 =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Error (Cause.Fail `Timeout) -> ()
             | _ -> fail "Queue.recv cancellation" "expected timeout" |> raise);
             let stats = Queue.stats queue in
             check_equal_int "Queue.cancelled_receivers" 1 stats.cancelled_receivers;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Effect.timeout Duration.zero (Queue.recv queue)))
       in
       p1);
  ]
