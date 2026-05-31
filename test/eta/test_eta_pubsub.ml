open Eta
open Test_eta_support

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
      | `Closed_with_error msg -> Format.fprintf fmt "`Closed_with_error %S" msg)
    ( = )

let pp_close_result fmt = function
  | `Closed -> Format.pp_print_string fmt "`Closed"
  | `Closed_with_error msg -> Format.fprintf fmt "`Closed_with_error %S" msg

let close_result :
    [ `Closed | `Closed_with_error of string ] Alcotest.testable =
  Alcotest.testable pp_close_result ( = )

let wait_for_waiting_publisher hub =
  Effect.sync (fun () ->
      wait_until (fun () -> (Pubsub.stats hub).Pubsub.waiting_publishers = 1))

let wait_for_cancelled_publisher hub =
  Effect.sync (fun () ->
      wait_until (fun () -> (Pubsub.stats hub).Pubsub.cancelled_publishers = 1))

let expect_closed rt eff =
  match Runtime.run rt eff with
  | Exit.Error (Cause.Fail `Closed) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected Closed, got %a"
        (Cause.pp (fun fmt -> function
          | `Closed -> Format.pp_print_string fmt "closed"
          | `Closed_with_error _ -> Format.pp_print_string fmt "closed_with_error"))
        cause
  | Exit.Ok _ -> Alcotest.fail "expected Closed"

let test_pubsub_unbounded_broadcasts_to_current_subscribers () =
  with_runtime @@ fun rt ->
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
    Effect.pure (r1, r2, [ a1; a2 ], [ b1; b2 ])
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
  with_runtime @@ fun rt ->
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
    Effect.pure ([ r1; r2; r3 ], [ first; second; third ])
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
  with_runtime @@ fun rt ->
  let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
  let program =
    let open Eta.Syntax in
    let* r1 = Pubsub.publish hub 10 in
    let* r2 = Pubsub.publish hub 20 in
    Pubsub.subscribe hub @@ fun sub ->
    let* after_subscribe = Pubsub.try_recv sub in
    Effect.pure (r1, r2, after_subscribe)
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
  with_runtime @@ fun rt ->
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
    Effect.pure (early_first, early_second, late_first, late_after)
  in
  let early_first, early_second, late_first, late_after = run_ok rt program in
  Alcotest.(check int) "early first" 1 early_first;
  Alcotest.(check int) "early second" 2 early_second;
  Alcotest.(check int) "late first" 2 late_first;
  Alcotest.check recv_result "late did not receive old message" `Empty
    late_after

let test_pubsub_many_publishers_many_subscribers_preserve_message_sets () =
  with_runtime @@ fun rt ->
  let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
  let program =
    let open Eta.Syntax in
    Pubsub.subscribe hub @@ fun a ->
    Pubsub.subscribe hub @@ fun b ->
    let publish_many publisher =
      Effect.for_each_par [ 1; 2; 3 ] (fun n ->
          Pubsub.publish hub (publisher, n) |> Effect.map (fun _ -> ()))
      |> Effect.map (fun _ -> ())
    in
    let* (), () = Effect.par (publish_many "left") (publish_many "right") in
    let* a_values =
      Effect.all
        (List.init 6 (fun _ -> Pubsub.recv a))
    in
    let* b_values =
      Effect.all
        (List.init 6 (fun _ -> Pubsub.recv b))
    in
    Effect.pure (a_values, b_values)
  in
  let sort_values =
    List.sort (fun (p1, n1) (p2, n2) ->
        match String.compare p1 p2 with 0 -> Int.compare n1 n2 | c -> c)
  in
  let expected =
    sort_values
      [ ("left", 1); ("left", 2); ("left", 3); ("right", 1); ("right", 2); ("right", 3) ]
  in
  let a_values, b_values = run_ok rt program in
  Alcotest.(check (list (pair string int))) "subscriber a message set" expected
    (sort_values a_values);
  Alcotest.(check (list (pair string int))) "subscriber b message set" expected
    (sort_values b_values)

let test_pubsub_drop_new_uses_global_capacity () =
  with_runtime @@ fun rt ->
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
    Effect.pure (r1, r2, first_a, r3, first_b, r4, second_a, second_b)
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
  with_runtime @@ fun rt ->
  let hub = Pubsub.create ~overflow:(Pubsub.Backpressure { capacity = 1 }) () in
  let ready = Queue.create () in
  let program =
    let open Eta.Syntax in
    Pubsub.subscribe hub @@ fun a ->
    Pubsub.subscribe hub @@ fun b ->
    let* _ = Pubsub.publish hub 1 in
    let* first_a = Pubsub.recv a in
    let blocked_publisher =
      let* () = Queue.send ready () in
      Pubsub.publish hub 2 |> Effect.map (fun _ -> `Published)
    in
    let cancel_after_blocked =
      let* () = Queue.recv ready in
      let* () = wait_for_waiting_publisher hub in
      Effect.pure `Canceled
    in
    let* race_result = Effect.race [ blocked_publisher; cancel_after_blocked ] in
    let* () = wait_for_cancelled_publisher hub in
    let* after_a = Pubsub.try_recv a in
    let* first_b = Pubsub.recv b in
    let* r3 = Pubsub.publish hub 3 in
    let* second_a = Pubsub.recv a in
    let* second_b = Pubsub.recv b in
    Effect.pure (race_result, first_a, after_a, first_b, r3, second_a, second_b)
  in
  let race_result, first_a, after_a, first_b, r3, second_a, second_b =
    run_ok rt program
  in
  Alcotest.(check (testable (fun fmt -> function
      | `Published -> Format.pp_print_string fmt "`Published"
      | `Canceled -> Format.pp_print_string fmt "`Canceled") ( = )))
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
  with_runtime @@ fun rt ->
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
      let* () = Effect.sync (fun () -> second_completed := true) in
      Effect.pure r2
    in
    let observer =
      let* () = wait_for_waiting_publisher hub in
      let before_b_receives = !second_completed in
      let* first_b = Pubsub.recv b in
      let* second_a = Pubsub.recv a in
      let* second_b = Pubsub.recv b in
      Effect.pure (before_b_receives, first_b, second_a, second_b)
    in
    let* r2, observed = Effect.par publisher observer in
    Effect.pure (first_a, r2, observed, !second_completed)
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
  with_runtime @@ fun rt ->
  let hub = Pubsub.create ~overflow:(Pubsub.Backpressure { capacity = 1 }) () in
  let program =
    let open Eta.Syntax in
    Pubsub.subscribe hub @@ fun _sub ->
    let* _ = Pubsub.publish hub 1 in
    let blocked_publisher =
      Pubsub.publish hub 2
      |> Effect.map (fun _ -> `Published)
      |> Effect.catch (function
           | `Closed -> Effect.pure `Closed
           | `Closed_with_error err -> Effect.pure (`Closed_with_error err))
    in
    let closer =
      let* () = wait_for_waiting_publisher hub in
      Effect.sync (fun () -> Pubsub.close hub)
    in
    Effect.par blocked_publisher closer |> Effect.map fst
  in
  (match run_ok rt program with
  | `Closed -> ()
  | `Published -> Alcotest.fail "blocked publisher unexpectedly published"
  | `Closed_with_error err ->
      Alcotest.failf "unexpected close error %s" err)

let test_pubsub_close_wakes_blocked_subscriber () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
  let holder = ref None in
  let ready = Queue.create () in
  let never = Queue.create () in
  let body =
    let open Eta.Syntax in
    Pubsub.subscribe hub @@ fun sub ->
    let* () = Effect.sync (fun () -> holder := Some sub) in
    let* () = Queue.send ready () in
    Queue.recv never
  in
  let body_fiber = fork_run sw rt body in
  run_ok rt (Queue.recv ready);
  let sub =
    match !holder with
    | Some sub -> sub
    | None -> Alcotest.fail "subscription was not captured"
  in
  let receiver = fork_run sw rt (Pubsub.recv sub) in
  wait_until (fun () -> (Pubsub.stats hub).Pubsub.waiting_receivers = 1);
  Pubsub.close hub;
  (match Eio.Promise.await receiver with
  | Exit.Error (Cause.Fail `Closed) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected Closed, got %a"
        (Cause.pp (fun fmt -> function
          | `Closed -> Format.pp_print_string fmt "closed"
          | `Closed_with_error _ -> Format.pp_print_string fmt "closed_with_error"))
        cause
  | Exit.Ok _ -> Alcotest.fail "expected Closed");
  Queue.close never;
  ignore (Eio.Promise.await body_fiber : (unit, [> `Closed ]) Exit.t)

let test_pubsub_close_with_error_drains_buffer () =
  with_runtime @@ fun rt ->
  let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
  let program =
    let open Eta.Syntax in
    Pubsub.subscribe hub @@ fun sub ->
    let* _ = Pubsub.publish hub 7 in
    let* () = Effect.sync (fun () -> Pubsub.close_with_error hub "boom") in
    let* first = Pubsub.recv sub in
    let* second =
      Pubsub.recv sub
      |> Effect.map (fun value -> `Unexpected_value value)
      |> Effect.catch (fun close -> Effect.pure (`Closed_as close))
    in
    Effect.pure (first, second)
  in
  let first, second = run_ok rt program in
  Alcotest.(check int) "buffered value" 7 first;
  Alcotest.(check (testable (fun fmt -> function
      | `Unexpected_value n -> Format.fprintf fmt "unexpected %d" n
      | `Closed_as close -> pp_close_result fmt close) ( = )))
    "typed close after drain" (`Closed_as (`Closed_with_error "boom"))
    second

let test_pubsub_subscription_cleanup_on_body_cancellation () =
  with_runtime @@ fun rt ->
  let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
  let leaked = ref None in
  let ready = Queue.create () in
  let never = Queue.create () in
  let program =
    let open Eta.Syntax in
    let body =
      Pubsub.subscribe hub @@ fun sub ->
      let* () = Effect.sync (fun () -> leaked := Some sub) in
      let* () = Queue.send ready () in
      Queue.recv never
    in
    let cancel_after_acquire =
      let* () = Queue.recv ready in
      Effect.pure ()
    in
    Effect.race [ body; cancel_after_acquire ]
  in
  ignore (run_ok rt program : unit);
  Alcotest.(check int) "subscriber removed" 0 (Pubsub.stats hub).subscribers;
  match !leaked with
  | None -> Alcotest.fail "expected leaked subscription from fixture"
  | Some sub -> expect_closed rt (Pubsub.recv sub)

let test_pubsub_cancel_blocked_recv_cleans_waiter () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
  let ready = Queue.create () in
  let never = Queue.create () in
  let holder = ref None in
  let body =
    let open Eta.Syntax in
    Pubsub.subscribe hub @@ fun sub ->
    let* () = Effect.sync (fun () -> holder := Some sub) in
    let* () = Queue.send ready () in
    Queue.recv never
  in
  let body_fiber = fork_run sw rt body in
  run_ok rt (Queue.recv ready);
  let sub =
    match !holder with
    | Some sub -> sub
    | None -> Alcotest.fail "subscription was not captured"
  in
  let cancel_ctx = ref None in
  let receiver =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Runtime.run rt (Pubsub.recv sub))
  in
  wait_until (fun () -> (Pubsub.stats hub).waiting_receivers = 1);
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  (match Eio.Promise.await_exn receiver with
  | Exit.Ok _ -> Alcotest.fail "expected cancellation"
  | Exit.Error _ -> ());
  Alcotest.(check int)
    "waiting receivers" 0 (Pubsub.stats hub).waiting_receivers;
  Alcotest.(check int)
    "cancelled receivers" 1 (Pubsub.stats hub).cancelled_receivers;
  ignore (run_ok rt (Pubsub.publish hub 42) : Pubsub.publish_result);
  Alcotest.(check int) "next recv gets published value" 42
    (run_ok rt (Pubsub.recv sub));
  Queue.close never;
  ignore (Eio.Promise.await body_fiber : (unit, [> `Closed ]) Exit.t)

let test_pubsub_invalid_capacity_rejected () =
  Alcotest.check_raises "drop_new zero capacity"
    (Invalid_argument "Eta.Pubsub.create: bounded capacity must be > 0")
    (fun () -> ignore (Pubsub.create ~overflow:(Pubsub.Drop_new { capacity = 0 }) ()));
  Alcotest.check_raises "backpressure zero capacity"
    (Invalid_argument "Eta.Pubsub.create: bounded capacity must be > 0")
    (fun () ->
      ignore (Pubsub.create ~overflow:(Pubsub.Backpressure { capacity = 0 }) ()))
