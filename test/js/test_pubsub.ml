open Test_support

let tests =
  [
    ("pubsub_sync",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
       (match Runtime.run_now runtime (Pubsub.publish hub 1) with
       | Some (Exit.Ok result) ->
           check_equal_int "Pubsub.publish no subscribers" 0 result.subscriber_count
       | _ -> fail "Pubsub.publish no subscribers" "expected publish result" |> raise);
       (match
          Runtime.run_now runtime
            (Pubsub.subscribe hub (fun sub ->
                 Effect.bind
                   (function
                     | `Empty -> Effect.pure ()
                     | _ -> Effect.fail `Closed)
                   (Pubsub.try_recv sub)))
        with
       | Some (Exit.Ok ()) -> ()
       | _ -> fail "Pubsub late subscriber" "expected empty" |> raise);
       let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
       (match
          Runtime.run_now runtime
            (Pubsub.subscribe hub (fun sub ->
                 Effect.bind
                   (fun publish ->
                     check_equal_int "Pubsub.subscriber_count" 1
                       publish.Pubsub.subscriber_count;
                     Pubsub.recv sub)
                   (Pubsub.publish hub 2)))
        with
       | Some exit -> check_exit_ok_int "Pubsub.recv published" 2 exit
       | None -> fail "Pubsub.recv published" "expected sync exit" |> raise);
       let stats = Pubsub.stats hub in
       check_equal_int "Pubsub.depth after release" 0 stats.depth;
       check_equal_int "Pubsub.subscribers after release" 0 stats.subscribers;
       let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
       (match
          Runtime.run_now runtime
            (Pubsub.subscribe hub (fun sub ->
                 Effect.seq (Effect.map (fun _ -> ()) (Pubsub.publish hub 3))
                   (Effect.seq
                      (Effect.sync (fun () -> Pubsub.close hub))
                      (Effect.bind
                         (fun value ->
                           check_equal_int "Pubsub.recv drains after close" 3 value;
                           Pubsub.recv sub)
                         (Pubsub.recv sub)))))
        with
       | Some (Exit.Error (Cause.Fail `Closed)) -> ()
       | _ -> fail "Pubsub close drain" "expected closed after drain" |> raise);
       let hub = Pubsub.create ~overflow:(Pubsub.Drop_new { capacity = 1 }) () in
       (match
          Runtime.run_now runtime
            (Pubsub.subscribe hub (fun _sub ->
                 Effect.bind
                   (fun first ->
                     check_equal_int "Pubsub.drop_new first subscribers" 1
                       first.Pubsub.subscriber_count;
                     Pubsub.publish hub 5)
                   (Pubsub.publish hub 4)))
        with
       | Some (Exit.Ok result) ->
           check_equal_int "Pubsub.drop_new dropped" 1 result.Pubsub.dropped
       | _ -> fail "Pubsub.drop_new" "expected dropped publish" |> raise);
       Js.Promise.resolve ());
    ("pubsub_publish_cancel",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let hub = Pubsub.create ~overflow:(Pubsub.Backpressure { capacity = 1 }) () in
       let p1 =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Error (Cause.Fail `Timeout) -> ()
             | _ -> fail "Pubsub.publish cancellation" "expected timeout" |> raise);
             let stats = Pubsub.stats hub in
             check_equal_int "Pubsub.cancelled_publishers" 1
               stats.cancelled_publishers;
             check_equal_int "Pubsub.depth after cancelled publisher" 0 stats.depth;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Pubsub.subscribe hub (fun _sub ->
                   Effect.seq
                     (Effect.map (fun _ -> ()) (Pubsub.publish hub 1))
                     (Effect.timeout Duration.zero (Pubsub.publish hub 2)))))
       in
       p1);
    ("pubsub_recv_cancel",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
       let p1 =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Error (Cause.Fail `Timeout) -> ()
             | _ -> fail "Pubsub.recv cancellation" "expected timeout" |> raise);
             let stats = Pubsub.stats hub in
             check_equal_int "Pubsub.cancelled_receivers" 1
               stats.cancelled_receivers;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Pubsub.subscribe hub (fun sub ->
                   Effect.timeout Duration.zero (Pubsub.recv sub))))
       in
       p1);
  ]
