open Eta

module Deferred_probe = struct
  type ('a, 'err) t = {
    promise : ('a, 'err) result Eio.Promise.t;
    resolver : ('a, 'err) result Eio.Promise.u;
    mutable done_ : bool;
  }

  let create () =
    let promise, resolver = Eio.Promise.create () in
    { promise; resolver; done_ = false }

  let await t =
    Effect.sync (fun () -> Eio.Promise.await t.promise)
    |> Effect.bind Effect.from_result

  let complete t result =
    Effect.sync (fun () ->
        if t.done_ then false
        else (
          t.done_ <- true;
          Eio.Promise.resolve t.resolver result;
          true))

  let succeed t value = complete t (Ok value)
  let fail t err = complete t (Error err)
  let is_done t = t.done_
end

module Pubsub_probe = struct
  type overflow =
    | Unbounded
    | Drop_new of { capacity : int }
    | Backpressure of { capacity : int }

  type publish_result = {
    subscriber_count : int;
    dropped : int;
  }

  type 'err close_reason =
    | Clean
    | Failed of 'err

  type ('a, 'err) mailbox =
    | Queue of ('a, 'err) Queue.t
    | Channel of ('a, 'err) Channel.t

  type ('a, 'err) subscription = {
    id : int;
    mailbox : ('a, 'err) mailbox;
    mutable active : bool;
  }

  type ('a, 'err) t = {
    overflow : overflow;
    mutable next_id : int;
    mutable close_reason : 'err close_reason option;
    mutable subscribers : ('a, 'err) subscription list;
  }

  let create ~overflow () =
    { overflow; next_id = 0; close_reason = None; subscribers = [] }

  let mailbox_of_overflow = function
    | Unbounded -> Queue (Queue.create ())
    | Drop_new { capacity } | Backpressure { capacity } ->
        Channel (Channel.create ~capacity ())

  let close_mailbox = function
    | Queue q -> Queue.close q
    | Channel ch -> Channel.close ch

  let close_mailbox_with_error mailbox err =
    match mailbox with
    | Queue q -> Queue.close_with_error q err
    | Channel ch -> Channel.close_with_error ch err

  let close t =
    match t.close_reason with
    | Some _ -> ()
    | None ->
        t.close_reason <- Some Clean;
        List.iter (fun sub -> close_mailbox sub.mailbox) t.subscribers

  let close_with_error t err =
    match t.close_reason with
    | Some _ -> ()
    | None ->
        t.close_reason <- Some (Failed err);
        List.iter
          (fun sub -> close_mailbox_with_error sub.mailbox err)
          t.subscribers

  let remove t sub =
    if sub.active then (
      sub.active <- false;
      t.subscribers <- List.filter (fun other -> other.id <> sub.id) t.subscribers;
      close_mailbox sub.mailbox)

  let add_subscription t =
    Effect.sync (fun () ->
        match t.close_reason with
        | Some Clean -> Error `Closed
        | Some (Failed err) -> Error (`Closed_with_error err)
        | None ->
            let sub =
              {
                id = t.next_id;
                mailbox = mailbox_of_overflow t.overflow;
                active = true;
              }
            in
            t.next_id <- t.next_id + 1;
            t.subscribers <- sub :: t.subscribers;
            Ok sub)
    |> Effect.bind Effect.from_result

  let subscribe t f =
    Effect.scoped
      (Effect.acquire_release ~acquire:(add_subscription t)
         ~release:(fun sub -> Effect.sync (fun () -> remove t sub))
      |> Effect.bind f)

  let recv sub =
    match sub.mailbox with
    | Queue q -> Queue.recv q
    | Channel ch -> Channel.recv ch

  let try_recv sub =
    match sub.mailbox with
    | Queue q -> Queue.try_recv q
    | Channel ch -> Channel.try_recv ch

  let fail_or_remove_closed t sub close_error =
    Effect.sync (fun () ->
        match t.close_reason with
        | Some Clean -> Error `Closed
        | Some (Failed err) -> Error (`Closed_with_error err)
        | None ->
            remove t sub;
            Ok { subscriber_count = 0; dropped = 0 })
    |> Effect.bind (function
         | Ok result -> Effect.pure result
         | Error `Closed -> (
             match close_error with
             | `Closed -> Effect.fail `Closed
             | `Closed_with_error err -> Effect.fail (`Closed_with_error err))
         | Error (`Closed_with_error err) -> Effect.fail (`Closed_with_error err))

  let deliver_one t value sub =
    if not sub.active then Effect.pure { subscriber_count = 0; dropped = 0 }
    else
      match sub.mailbox with
      | Queue q ->
          Queue.send q value
          |> Effect.map (fun () -> { subscriber_count = 1; dropped = 0 })
          |> Effect.catch (fun close_error ->
                 fail_or_remove_closed t sub close_error)
      | Channel ch -> (
          match t.overflow with
          | Drop_new _ ->
              Channel.try_send ch value
              |> Effect.bind (function
                   | `Sent -> Effect.pure { subscriber_count = 1; dropped = 0 }
                   | `Full -> Effect.pure { subscriber_count = 1; dropped = 1 }
                   | `Closed -> fail_or_remove_closed t sub `Closed
                   | `Closed_with_error err ->
                       fail_or_remove_closed t sub (`Closed_with_error err))
          | Backpressure _ ->
              Channel.send ch value
              |> Effect.map (fun () -> { subscriber_count = 1; dropped = 0 })
              |> Effect.catch (fun close_error ->
                     fail_or_remove_closed t sub close_error)
          | Unbounded -> failwith "unbounded pubsub uses Queue mailbox")

  let publish t value =
    Effect.sync (fun () ->
        match t.close_reason with
        | Some Clean -> Error `Closed
        | Some (Failed err) -> Error (`Closed_with_error err)
        | None -> Ok (List.rev t.subscribers))
    |> Effect.bind Effect.from_result
    |> Effect.bind (fun subscribers ->
           let rec loop (total : publish_result) = function
             | [] -> Effect.pure total
             | sub :: rest ->
                 deliver_one t value sub
                 |> Effect.bind (fun result ->
                        loop
                          {
                            subscriber_count =
                              total.subscriber_count + result.subscriber_count;
                            dropped = total.dropped + result.dropped;
                          }
                          rest)
           in
           loop { subscriber_count = 0; dropped = 0 } subscribers)
end

module Raw_queue_candidate = struct
  type ('a, 'err) t = {
    mutable subscribers : ('a, 'err) Queue.t list;
  }

  let create () = { subscribers = [] }

  let remove t q =
    t.subscribers <- List.filter (fun other -> other != q) t.subscribers;
    Queue.close q

  let subscribe t f =
    let acquire =
      Effect.sync (fun () ->
          let q = Queue.create () in
          t.subscribers <- q :: t.subscribers;
          q)
    in
    Effect.scoped
      (Effect.acquire_release ~acquire ~release:(fun q ->
           Effect.sync (fun () -> remove t q))
      |> Effect.bind f)

  let publish t value =
    let rec loop active kept = function
      | [] ->
          t.subscribers <- List.rev kept;
          Effect.pure active
      | q :: rest ->
          Queue.try_send q value
          |> Effect.bind (function
               | `Sent -> loop (active + 1) (q :: kept) rest
               | `Closed | `Closed_with_error _ -> loop active kept rest)
    in
    loop 0 [] t.subscribers
end

let yield = Effect.sync Eio.Fiber.yield

let with_runtime f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  f rt

let run_ok rt eff =
  match Runtime.run rt eff with
  | Exit.Ok value -> value
  | Exit.Error _ -> Alcotest.fail "unexpected effect failure"

open Pubsub_probe

let pp_close_error fmt = function
  | `Closed -> Format.pp_print_string fmt "`Closed"
  | `Closed_with_error msg -> Format.fprintf fmt "`Closed_with_error %S" msg

let close_error = Alcotest.testable pp_close_error ( = )

let expect_close_failure rt eff expected =
  match Runtime.run rt eff with
  | Exit.Error (Cause.Fail actual) ->
      Alcotest.check close_error "close failure" expected actual
  | Exit.Error _ -> Alcotest.fail "expected simple typed close failure"
  | Exit.Ok _ -> Alcotest.fail "expected effect failure"

let expect_closed rt eff =
  match Runtime.run rt eff with
  | Exit.Error (Cause.Fail `Closed) -> ()
  | Exit.Error _ -> Alcotest.fail "expected simple closed failure"
  | Exit.Ok _ -> Alcotest.fail "expected closed failure"

let publish_result =
  Alcotest.testable
    (fun fmt result ->
      Format.fprintf fmt "{ subscriber_count = %d; dropped = %d }"
        result.subscriber_count result.dropped)
    ( = )

let test_deferred_first_completion_wins () =
  with_runtime @@ fun rt ->
  let d = Deferred_probe.create () in
  let program =
    let open Eta.Syntax in
    let awaiters = Effect.all [ Deferred_probe.await d; Deferred_probe.await d ] in
    let completer =
      let* first = Deferred_probe.succeed d 1 in
      let* second = Deferred_probe.succeed d 2 in
      Effect.pure (first, second, Deferred_probe.is_done d)
    in
    Effect.par awaiters completer
  in
  let values, completions = run_ok rt program in
  Alcotest.(check (list int)) "all awaiters saw first value" [ 1; 1 ] values;
  Alcotest.(check (triple bool bool bool))
    "first completion wins" (true, false, true) completions

let test_deferred_failed_result_replays_to_late_awaiter () =
  with_runtime @@ fun rt ->
  let d = Deferred_probe.create () in
  ignore (run_ok rt (Deferred_probe.fail d "boom") : bool);
  match Runtime.run rt (Deferred_probe.await d) with
  | Exit.Error (Cause.Fail "boom") -> ()
  | Exit.Error _ -> Alcotest.fail "expected typed deferred failure"
  | Exit.Ok _ -> Alcotest.fail "expected deferred failure"

let test_pubsub_unbounded_broadcasts_to_current_subscribers () =
  with_runtime @@ fun rt ->
  let hub = Pubsub_probe.create ~overflow:Pubsub_probe.Unbounded () in
  let program =
    let open Eta.Syntax in
    Pubsub_probe.subscribe hub @@ fun a ->
    Pubsub_probe.subscribe hub @@ fun b ->
    let* r1 = Pubsub_probe.publish hub 10 in
    let* r2 = Pubsub_probe.publish hub 20 in
    let* a1 = Pubsub_probe.recv a in
    let* a2 = Pubsub_probe.recv a in
    let* b1 = Pubsub_probe.recv b in
    let* b2 = Pubsub_probe.recv b in
    Effect.pure (r1, r2, [ a1; a2 ], [ b1; b2 ])
  in
  let r1, r2, a_values, b_values = run_ok rt program in
  Alcotest.check publish_result "publish 1"
    { subscriber_count = 2; dropped = 0 } r1;
  Alcotest.check publish_result "publish 2"
    { subscriber_count = 2; dropped = 0 } r2;
  Alcotest.(check (list int)) "subscriber a" [ 10; 20 ] a_values;
  Alcotest.(check (list int)) "subscriber b" [ 10; 20 ] b_values

let test_pubsub_drop_new_reports_per_subscriber_drops () =
  with_runtime @@ fun rt ->
  let hub =
    Pubsub_probe.create ~overflow:(Pubsub_probe.Drop_new { capacity = 1 }) ()
  in
  let program =
    let open Eta.Syntax in
    Pubsub_probe.subscribe hub @@ fun a ->
    Pubsub_probe.subscribe hub @@ fun b ->
    let* r1 = Pubsub_probe.publish hub 1 in
    let* r2 = Pubsub_probe.publish hub 2 in
    let* r3 = Pubsub_probe.publish hub 3 in
    let* a1 = Pubsub_probe.recv a in
    let* b1 = Pubsub_probe.recv b in
    Effect.pure (r1, r2, r3, a1, b1)
  in
  let r1, r2, r3, a1, b1 = run_ok rt program in
  Alcotest.check publish_result "first publish accepted by both"
    { subscriber_count = 2; dropped = 0 } r1;
  Alcotest.check publish_result "second publish dropped for both"
    { subscriber_count = 2; dropped = 2 } r2;
  Alcotest.check publish_result "third publish dropped for both"
    { subscriber_count = 2; dropped = 2 } r3;
  Alcotest.(check int) "subscriber a kept first" 1 a1;
  Alcotest.(check int) "subscriber b kept first" 1 b1

let test_pubsub_scoped_subscription_closes_escaped_handle () =
  with_runtime @@ fun rt ->
  let hub = Pubsub_probe.create ~overflow:Pubsub_probe.Unbounded () in
  let leaked = ref None in
  let program =
    Pubsub_probe.subscribe hub (fun sub ->
        Effect.sync (fun () -> leaked := Some sub))
  in
  run_ok rt program;
  match !leaked with
  | None -> Alcotest.fail "expected leaked subscription from fixture"
  | Some sub -> expect_closed rt (Pubsub_probe.recv sub)

let test_pubsub_body_failure_closes_escaped_handle () =
  with_runtime @@ fun rt ->
  let hub = Pubsub_probe.create ~overflow:Pubsub_probe.Unbounded () in
  let leaked = ref None in
  let program =
    let open Eta.Syntax in
    Pubsub_probe.subscribe hub @@ fun sub ->
    let* () = Effect.sync (fun () -> leaked := Some sub) in
    Effect.fail `Body_failed
  in
  (match Runtime.run rt program with
  | Exit.Error (Cause.Fail `Body_failed) -> ()
  | Exit.Error _ -> Alcotest.fail "expected body failure"
  | Exit.Ok _ -> Alcotest.fail "expected failed subscription body");
  match !leaked with
  | None -> Alcotest.fail "expected leaked subscription from fixture"
  | Some sub -> expect_closed rt (Pubsub_probe.recv sub)

let test_pubsub_body_cancellation_closes_escaped_handle () =
  with_runtime @@ fun rt ->
  let hub = Pubsub_probe.create ~overflow:Pubsub_probe.Unbounded () in
  let leaked = ref None in
  let ready = Queue.create () in
  let never = Queue.create () in
  let program =
    let open Eta.Syntax in
    let body =
      Pubsub_probe.subscribe hub @@ fun sub ->
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
  match !leaked with
  | None -> Alcotest.fail "expected leaked subscription from fixture"
  | Some sub -> expect_closed rt (Pubsub_probe.recv sub)

let test_pubsub_close_with_error_drains_buffer_then_fails () =
  with_runtime @@ fun rt ->
  let hub = Pubsub_probe.create ~overflow:Pubsub_probe.Unbounded () in
  let program =
    let open Eta.Syntax in
    Pubsub_probe.subscribe hub @@ fun sub ->
    let* _ = Pubsub_probe.publish hub 7 in
    let* () = Effect.sync (fun () -> Pubsub_probe.close_with_error hub "boom") in
    let* first = Pubsub_probe.recv sub in
    let* second =
      Pubsub_probe.recv sub
      |> Effect.map (fun value -> `Unexpected_value value)
      |> Effect.catch (fun close_error -> Effect.pure (`Closed_as close_error))
    in
    Effect.pure (first, second)
  in
  let first, second = run_ok rt program in
  Alcotest.(check int) "buffer drained" 7 first;
  Alcotest.(check (testable (fun fmt -> function
      | `Unexpected_value n -> Format.fprintf fmt "unexpected %d" n
      | `Closed_as err -> pp_close_error fmt err) ( = )))
    "typed close after drain" (`Closed_as (`Closed_with_error "boom")) second

let test_pubsub_backpressure_blocks_until_receive () =
  with_runtime @@ fun rt ->
  let hub =
    Pubsub_probe.create ~overflow:(Pubsub_probe.Backpressure { capacity = 1 }) ()
  in
  let second_completed = ref false in
  let program =
    let open Eta.Syntax in
    Pubsub_probe.subscribe hub @@ fun sub ->
    let publisher =
      let* _ = Pubsub_probe.publish hub 1 in
      let* _ = Pubsub_probe.publish hub 2 in
      Effect.sync (fun () -> second_completed := true)
    in
    let observer =
      let* () = yield in
      let* () = yield in
      let before_receive = !second_completed in
      let* first = Pubsub_probe.recv sub in
      let* () = yield in
      let* second = Pubsub_probe.recv sub in
      Effect.pure (before_receive, first, second, !second_completed)
    in
    Effect.par publisher observer |> Effect.map snd
  in
  let before_receive, first, second, after_receive = run_ok rt program in
  Alcotest.(check bool) "second publish blocked before receive" false before_receive;
  Alcotest.(check int) "first value" 1 first;
  Alcotest.(check int) "second value" 2 second;
  Alcotest.(check bool) "second publish completed after receive" true after_receive

let test_pubsub_close_wakes_blocked_backpressure_publisher () =
  with_runtime @@ fun rt ->
  let hub =
    Pubsub_probe.create ~overflow:(Pubsub_probe.Backpressure { capacity = 1 }) ()
  in
  let program =
    let open Eta.Syntax in
    Pubsub_probe.subscribe hub @@ fun _sub ->
    let* _ = Pubsub_probe.publish hub 1 in
    let blocked_publisher =
      Pubsub_probe.publish hub 2
      |> Effect.map (fun _ -> `Published)
      |> Effect.catch (function
           | `Closed -> Effect.pure `Closed
           | `Closed_with_error err -> Effect.pure (`Closed_with_error err))
    in
    let closer =
      let* () = yield in
      Effect.sync (fun () -> Pubsub_probe.close hub)
    in
    Effect.par blocked_publisher closer |> Effect.map fst
  in
  Alcotest.(check (testable (fun fmt -> function
      | `Published -> Format.pp_print_string fmt "`Published"
      | `Closed -> Format.pp_print_string fmt "`Closed"
      | `Closed_with_error msg -> Format.fprintf fmt "`Closed_with_error %S" msg)
      ( = )))
    "blocked publisher woke on close" `Closed (run_ok rt program)

let test_pubsub_cancelled_backpressure_publish_does_not_leave_waiter () =
  with_runtime @@ fun rt ->
  let hub =
    Pubsub_probe.create ~overflow:(Pubsub_probe.Backpressure { capacity = 1 }) ()
  in
  let ready = Queue.create () in
  let program =
    let open Eta.Syntax in
    Pubsub_probe.subscribe hub @@ fun sub ->
    let* _ = Pubsub_probe.publish hub 1 in
    let blocked_publisher =
      let* () = Queue.send ready () in
      let* _ = Pubsub_probe.publish hub 2 in
      Effect.pure `Published
    in
    let cancel_after_blocked =
      let* () = Queue.recv ready in
      Effect.pure `Canceled
    in
    let* race_result = Effect.race [ blocked_publisher; cancel_after_blocked ] in
    let* first = Pubsub_probe.recv sub in
    let* r3 = Pubsub_probe.publish hub 3 in
    let* second = Pubsub_probe.recv sub in
    Effect.pure (race_result, first, r3, second)
  in
  let race_result, first, r3, second = run_ok rt program in
  Alcotest.(check (testable (fun fmt -> function
      | `Published -> Format.pp_print_string fmt "`Published"
      | `Canceled -> Format.pp_print_string fmt "`Canceled") ( = )))
    "blocked publisher was canceled" `Canceled race_result;
  Alcotest.(check int) "first value" 1 first;
  Alcotest.check publish_result "publish after cancellation"
    { subscriber_count = 1; dropped = 0 } r3;
  Alcotest.(check int) "canceled value was not delivered" 3 second

let test_pubsub_channel_backpressure_allows_partial_canceled_publish () =
  with_runtime @@ fun rt ->
  let hub =
    Pubsub_probe.create ~overflow:(Pubsub_probe.Backpressure { capacity = 1 }) ()
  in
  let program =
    let open Eta.Syntax in
    Pubsub_probe.subscribe hub @@ fun a ->
    Pubsub_probe.subscribe hub @@ fun b ->
    let* _ = Pubsub_probe.publish hub 1 in
    let* first_a = Pubsub_probe.recv a in
    let blocked_publisher =
      Pubsub_probe.publish hub 2 |> Effect.map (fun _ -> `Published)
    in
    let cancel_after_a_gets_second =
      let* second_a = Pubsub_probe.recv a in
      Effect.pure (`Partial second_a)
    in
    let* race_result =
      Effect.race [ blocked_publisher; cancel_after_a_gets_second ]
    in
    let* first_b = Pubsub_probe.recv b in
    let* after_b = Pubsub_probe.try_recv b in
    Effect.pure (first_a, race_result, first_b, after_b)
  in
  let first_a, race_result, first_b, after_b = run_ok rt program in
  Alcotest.(check int) "subscriber a first value" 1 first_a;
  Alcotest.(check (testable (fun fmt -> function
      | `Published -> Format.pp_print_string fmt "`Published"
      | `Partial n -> Format.fprintf fmt "`Partial %d" n) ( = )))
    "publish was canceled after reaching first subscriber" (`Partial 2)
    race_result;
  Alcotest.(check int) "subscriber b first value" 1 first_b;
  Alcotest.(check (testable (fun fmt -> function
      | `Item n -> Format.fprintf fmt "`Item %d" n
      | `Empty -> Format.pp_print_string fmt "`Empty"
      | `Closed -> Format.pp_print_string fmt "`Closed"
      | `Closed_with_error msg -> Format.fprintf fmt "`Closed_with_error %S" msg)
      ( = )))
    "subscriber b did not receive canceled publish" `Empty after_b

let shared_publish_result =
  Alcotest.testable
    (fun fmt (result : Shared_hub_probe.publish_result) ->
      Format.fprintf fmt "{ subscriber_count = %d; dropped = %d }"
        result.subscriber_count result.dropped)
    ( = )

let shared_try_recv_result =
  Alcotest.testable
    (fun fmt -> function
      | `Item n -> Format.fprintf fmt "`Item %d" n
      | `Empty -> Format.pp_print_string fmt "`Empty"
      | `Closed -> Format.pp_print_string fmt "`Closed"
      | `Closed_with_error msg -> Format.fprintf fmt "`Closed_with_error %S" msg)
    ( = )

let wait_for_shared_waiting_publisher hub =
  Effect.sync (fun () ->
      while (Shared_hub_probe.stats hub).waiting_publishers = 0 do
        Eio.Fiber.yield ()
      done)

let test_shared_hub_backpressure_canceled_publish_is_atomic () =
  with_runtime @@ fun rt ->
  let hub =
    Shared_hub_probe.create
      ~overflow:(Shared_hub_probe.Backpressure { capacity = 1 })
      ()
  in
  let ready = Queue.create () in
  let program =
    let open Eta.Syntax in
    Shared_hub_probe.subscribe hub @@ fun a ->
    Shared_hub_probe.subscribe hub @@ fun b ->
    let* _ = Shared_hub_probe.publish hub 1 in
    let* first_a = Shared_hub_probe.recv a in
    let blocked_publisher =
      let* () = Queue.send ready () in
      Shared_hub_probe.publish hub 2 |> Effect.map (fun _ -> `Published)
    in
    let cancel_after_blocked =
      let* () = Queue.recv ready in
      let* () = wait_for_shared_waiting_publisher hub in
      Effect.pure `Canceled
    in
    let* race_result = Effect.race [ blocked_publisher; cancel_after_blocked ] in
    let* after_a = Shared_hub_probe.try_recv a in
    let* first_b = Shared_hub_probe.recv b in
    let* r3 = Shared_hub_probe.publish hub 3 in
    let* second_a = Shared_hub_probe.recv a in
    let* second_b = Shared_hub_probe.recv b in
    Effect.pure (race_result, first_a, after_a, first_b, r3, second_a, second_b)
  in
  let race_result, first_a, after_a, first_b, r3, second_a, second_b =
    run_ok rt program
  in
  Alcotest.(check (testable (fun fmt -> function
      | `Published -> Format.pp_print_string fmt "`Published"
      | `Canceled -> Format.pp_print_string fmt "`Canceled") ( = )))
    "blocked publisher was canceled" `Canceled race_result;
  Alcotest.(check int) "subscriber a first value" 1 first_a;
  Alcotest.check shared_try_recv_result
    "subscriber a did not receive canceled publish" `Empty after_a;
  Alcotest.(check int) "subscriber b first value" 1 first_b;
  Alcotest.check shared_publish_result "publish after cancellation"
    { Shared_hub_probe.subscriber_count = 2; dropped = 0 }
    r3;
  Alcotest.(check int) "subscriber a next value skips canceled publish" 3 second_a;
  Alcotest.(check int) "subscriber b next value skips canceled publish" 3 second_b;
  Alcotest.(check int)
    "canceled publisher counted" 1
    (Shared_hub_probe.stats hub).cancelled_publishers

let test_shared_hub_backpressure_waits_for_lagging_subscriber () =
  with_runtime @@ fun rt ->
  let hub =
    Shared_hub_probe.create
      ~overflow:(Shared_hub_probe.Backpressure { capacity = 1 })
      ()
  in
  let program =
    let open Eta.Syntax in
    Shared_hub_probe.subscribe hub @@ fun a ->
    Shared_hub_probe.subscribe hub @@ fun b ->
    let* _ = Shared_hub_probe.publish hub 1 in
    let* first_a = Shared_hub_probe.recv a in
    let second_completed = ref false in
    let publisher =
      let* r2 = Shared_hub_probe.publish hub 2 in
      let* () = Effect.sync (fun () -> second_completed := true) in
      Effect.pure r2
    in
    let observer =
      let* () = wait_for_shared_waiting_publisher hub in
      let before_b_receives = !second_completed in
      let* first_b = Shared_hub_probe.recv b in
      let* second_a = Shared_hub_probe.recv a in
      let* second_b = Shared_hub_probe.recv b in
      Effect.pure (before_b_receives, first_b, second_a, second_b)
    in
    let* r2, observed = Effect.par publisher observer in
    Effect.pure (first_a, r2, observed, !second_completed)
  in
  let first_a, r2, (before_b_receives, first_b, second_a, second_b), after =
    run_ok rt program
  in
  Alcotest.(check int) "subscriber a first value" 1 first_a;
  Alcotest.(check bool) "second publish waited for subscriber b" false
    before_b_receives;
  Alcotest.(check int) "subscriber b first value" 1 first_b;
  Alcotest.check shared_publish_result "second publish result"
    { Shared_hub_probe.subscriber_count = 2; dropped = 0 }
    r2;
  Alcotest.(check int) "subscriber a second value" 2 second_a;
  Alcotest.(check int) "subscriber b second value" 2 second_b;
  Alcotest.(check bool) "second publish completed" true after

let test_shared_hub_drop_new_is_global_capacity_policy () =
  with_runtime @@ fun rt ->
  let hub =
    Shared_hub_probe.create
      ~overflow:(Shared_hub_probe.Drop_new { capacity = 1 })
      ()
  in
  let program =
    let open Eta.Syntax in
    Shared_hub_probe.subscribe hub @@ fun a ->
    Shared_hub_probe.subscribe hub @@ fun b ->
    let* r1 = Shared_hub_probe.publish hub 1 in
    let* r2 = Shared_hub_probe.publish hub 2 in
    let* first_a = Shared_hub_probe.recv a in
    let* r3 = Shared_hub_probe.publish hub 3 in
    let* first_b = Shared_hub_probe.recv b in
    let* r4 = Shared_hub_probe.publish hub 4 in
    let* second_a = Shared_hub_probe.recv a in
    let* second_b = Shared_hub_probe.recv b in
    Effect.pure (r1, r2, first_a, r3, first_b, r4, second_a, second_b)
  in
  let r1, r2, first_a, r3, first_b, r4, second_a, second_b =
    run_ok rt program
  in
  Alcotest.check shared_publish_result "first publish accepted"
    { Shared_hub_probe.subscriber_count = 2; dropped = 0 }
    r1;
  Alcotest.check shared_publish_result "second publish dropped globally"
    { Shared_hub_probe.subscriber_count = 2; dropped = 2 }
    r2;
  Alcotest.(check int) "subscriber a first value" 1 first_a;
  Alcotest.check shared_publish_result
    "third publish still dropped while subscriber b lags"
    { Shared_hub_probe.subscriber_count = 2; dropped = 2 }
    r3;
  Alcotest.(check int) "subscriber b first value" 1 first_b;
  Alcotest.check shared_publish_result "fourth publish accepted after drain"
    { Shared_hub_probe.subscriber_count = 2; dropped = 0 }
    r4;
  Alcotest.(check int) "subscriber a receives next admitted value" 4 second_a;
  Alcotest.(check int) "subscriber b receives next admitted value" 4 second_b

let test_shared_hub_close_with_error_drains_then_fails () =
  with_runtime @@ fun rt ->
  let hub = Shared_hub_probe.create ~overflow:Shared_hub_probe.Unbounded () in
  let program =
    let open Eta.Syntax in
    Shared_hub_probe.subscribe hub @@ fun sub ->
    let* _ = Shared_hub_probe.publish hub 7 in
    let* () =
      Effect.sync (fun () -> Shared_hub_probe.close_with_error hub "boom")
    in
    let* first = Shared_hub_probe.recv sub in
    let* second =
      Shared_hub_probe.recv sub
      |> Effect.map (fun value -> `Unexpected_value value)
      |> Effect.catch (fun close_error -> Effect.pure (`Closed_as close_error))
    in
    Effect.pure (first, second)
  in
  let first, second = run_ok rt program in
  Alcotest.(check int) "buffered value" 7 first;
  Alcotest.(check (testable (fun fmt -> function
      | `Unexpected_value n -> Format.fprintf fmt "unexpected %d" n
      | `Closed_as err -> pp_close_error fmt err) ( = )))
    "typed close after drain" (`Closed_as (`Closed_with_error "boom")) second

let test_shared_hub_body_cancellation_closes_escaped_handle () =
  with_runtime @@ fun rt ->
  let hub = Shared_hub_probe.create ~overflow:Shared_hub_probe.Unbounded () in
  let leaked = ref None in
  let ready = Queue.create () in
  let never = Queue.create () in
  let program =
    let open Eta.Syntax in
    let body =
      Shared_hub_probe.subscribe hub @@ fun sub ->
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
  match !leaked with
  | None -> Alcotest.fail "expected leaked subscription from fixture"
  | Some sub -> expect_closed rt (Shared_hub_probe.recv sub)

let test_raw_queue_candidate_allows_user_to_close_subscription () =
  with_runtime @@ fun rt ->
  let hub = Raw_queue_candidate.create () in
  let program =
    let open Eta.Syntax in
    Raw_queue_candidate.subscribe hub @@ fun q ->
    let* () = Effect.sync (fun () -> Queue.close q) in
    Raw_queue_candidate.publish hub 1
  in
  Alcotest.(check int)
    "raw Queue.t exposure lets user close active subscription" 0
    (run_ok rt program)

let () =
  Alcotest.run "deferred_pubsub_research"
    [
      ( "deferred",
        [
          Alcotest.test_case "first completion wins" `Quick
            test_deferred_first_completion_wins;
          Alcotest.test_case "failure replays to late awaiter" `Quick
            test_deferred_failed_result_replays_to_late_awaiter;
        ] );
      ( "pubsub",
        [
          Alcotest.test_case "unbounded broadcasts" `Quick
            test_pubsub_unbounded_broadcasts_to_current_subscribers;
          Alcotest.test_case "drop_new reports drops" `Quick
            test_pubsub_drop_new_reports_per_subscriber_drops;
          Alcotest.test_case "scoped subscription closes escaped handle" `Quick
            test_pubsub_scoped_subscription_closes_escaped_handle;
          Alcotest.test_case "body failure closes escaped handle" `Quick
            test_pubsub_body_failure_closes_escaped_handle;
          Alcotest.test_case "body cancellation closes escaped handle" `Quick
            test_pubsub_body_cancellation_closes_escaped_handle;
          Alcotest.test_case "close_with_error drains then fails" `Quick
            test_pubsub_close_with_error_drains_buffer_then_fails;
          Alcotest.test_case "backpressure blocks until receive" `Quick
            test_pubsub_backpressure_blocks_until_receive;
          Alcotest.test_case "close wakes blocked backpressure publisher" `Quick
            test_pubsub_close_wakes_blocked_backpressure_publisher;
          Alcotest.test_case "cancelled backpressure publish leaves no waiter"
            `Quick
            test_pubsub_cancelled_backpressure_publish_does_not_leave_waiter;
          Alcotest.test_case
            "channel backpressure permits partial canceled publish" `Quick
            test_pubsub_channel_backpressure_allows_partial_canceled_publish;
          Alcotest.test_case
            "shared hub backpressure canceled publish is atomic" `Quick
            test_shared_hub_backpressure_canceled_publish_is_atomic;
          Alcotest.test_case
            "shared hub backpressure waits for lagging subscriber" `Quick
            test_shared_hub_backpressure_waits_for_lagging_subscriber;
          Alcotest.test_case "shared hub drop_new is global capacity" `Quick
            test_shared_hub_drop_new_is_global_capacity_policy;
          Alcotest.test_case "shared hub close_with_error drains" `Quick
            test_shared_hub_close_with_error_drains_then_fails;
          Alcotest.test_case "shared hub body cancellation cleans subscription"
            `Quick
            test_shared_hub_body_cancellation_closes_escaped_handle;
          Alcotest.test_case "raw queue exposure negative fixture" `Quick
            test_raw_queue_candidate_allows_user_to_close_subscription;
        ] );
    ]
