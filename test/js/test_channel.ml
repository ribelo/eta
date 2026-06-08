open Test_support

let tests =
  [
    ("channel_sync",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let channel = Channel.create ~capacity:1 () in
       (match Runtime.run_now runtime (Channel.try_send channel 1) with
       | Some (Exit.Ok `Sent) -> ()
       | _ -> fail "Channel.try_send sent" "expected sent" |> raise);
       (match Runtime.run_now runtime (Channel.try_send channel 2) with
       | Some (Exit.Ok `Full) -> ()
       | _ -> fail "Channel.try_send full" "expected full" |> raise);
       (match Runtime.run_now runtime (Channel.recv channel) with
       | Some exit -> check_exit_ok_int "Channel.recv buffered" 1 exit
       | None -> fail "Channel.recv buffered" "expected sync exit" |> raise);
       (match Runtime.run_now runtime (Channel.send channel 2) with
       | Some exit -> check_exit_ok_unit "Channel.send" exit
       | None -> fail "Channel.send" "expected sync exit" |> raise);
       Channel.close channel;
       (match Runtime.run_now runtime (Channel.recv channel) with
       | Some exit -> check_exit_ok_int "Channel.recv drains after close" 2 exit
       | None -> fail "Channel.recv drains after close" "expected sync exit" |> raise);
       (match Runtime.run_now runtime (Channel.recv channel) with
       | Some (Exit.Error (Cause.Fail `Closed)) -> ()
       | _ -> fail "Channel.recv closed" "expected closed failure" |> raise);
       let stats = Channel.stats channel in
       check_equal_int "Channel.stats sent" 2 stats.sent;
       check_equal_int "Channel.stats received" 2 stats.received;
       check "Channel.stats closed" stats.closed;
       Js.Promise.resolve ());
    ("channel_send_waits",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let channel = Channel.create ~capacity:1 () in
       (match Runtime.run_now runtime (Channel.send channel 1) with
       | Some exit -> check_exit_ok_unit "Channel initial send" exit
       | None -> fail "Channel initial send" "expected sync exit" |> raise);
       let p1 =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_unit "Channel.send waits" exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime (Channel.send channel 2))
       in
       let stats = Channel.stats channel in
       check_equal_int "Channel.waiting_senders before recv" 1 stats.waiting_senders;
       (match Runtime.run_now runtime (Channel.recv channel) with
       | Some exit -> check_exit_ok_int "Channel.recv opens capacity" 1 exit
       | None -> fail "Channel.recv opens capacity" "expected sync exit" |> raise);
       (match Runtime.run_now runtime (Channel.recv channel) with
       | Some exit -> check_exit_ok_int "Channel.recv admitted sender" 2 exit
       | None -> fail "Channel.recv admitted sender" "expected sync exit" |> raise);
       p1);
    ("channel_send_cancel",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let channel = Channel.create ~capacity:1 () in
       (match Runtime.run_now runtime (Channel.send channel 1) with
       | Some exit -> check_exit_ok_unit "Channel cancel initial send" exit
       | None -> fail "Channel cancel initial send" "expected sync exit" |> raise);
       let p1 =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Error (Cause.Fail `Timeout) -> ()
             | _ -> fail "Channel.send cancellation" "expected timeout" |> raise);
             let stats = Channel.stats channel in
             check_equal_int "Channel.cancelled_senders" 1 stats.cancelled_senders;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Effect.timeout Duration.zero (Channel.send channel 2)))
       in
       p1);
  ]
