module Bridge = Eta_signal_stream_bridge
module Cause = Eta.Cause
module Delivery_handle = Eta_signal_observer.Delivery_handle
module Effect = Eta.Effect
module Observer = Eta_signal_observer

let pp_hidden ppf _ = Format.pp_print_string ppf "<stream-bridge-error>"

let run_ok runtime effect =
  match Eta_eio.Runtime.run runtime effect with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause

let wait_until label predicate =
  let rec loop attempts =
    if predicate () then ()
    else if attempts = 0 then Alcotest.failf "timed out waiting for %s" label
    else (
      Eta_test.Async.yield ();
      loop (attempts - 1))
  in
  loop 50

let await_cancelled label promise =
  try
    match Eio.Promise.await_exn promise with
    | Eta.Exit.Ok _ -> Alcotest.failf "%s: expected Eio cancellation, got Ok" label
    | Eta.Exit.Error cause ->
        Alcotest.failf "%s: expected Eio cancellation, got %a" label
          (Cause.pp pp_hidden) cause
  with Eio.Cancel.Cancelled _ -> ()

let changed ~old_value ~new_value =
  Observer.Update.Changed { old_value; new_value }

let check_changed label ~old_value ~new_value = function
  | Observer.Update.Changed
      { old_value = actual_old; new_value = actual_new } ->
      Alcotest.(check int) (label ^ " old") old_value actual_old;
      Alcotest.(check int) (label ^ " new") new_value actual_new
  | Observer.Update.Initialized _ ->
      Alcotest.failf "%s: expected Changed update" label

type live = {
  mutable snapshot : (int, unit -> unit) Observer.Snapshot.t;
  mutable after_ack_count : int;
}

let make_delivery_port live =
  Observer.delivery_port
    ~live:(fun () () -> Some live)
    ~snapshot:(fun () live -> live.snapshot)
    ~set_snapshot:(fun () live snapshot -> live.snapshot <- snapshot)
    ~run_after_ack:(fun () hooks ->
      live.after_ack_count <- live.after_ack_count + List.length hooks;
      List.iter (fun hook -> hook ()) hooks)

let make_queue capacity =
  match Bridge.create_queue ~capacity with
  | Ok queue -> queue
  | Error `Invalid_capacity -> Alcotest.fail "unexpected invalid capacity"

let check_delivered label expected live =
  match Observer.Snapshot.delivery live.snapshot with
  | Observer.Delivery.Observer_delivered actual ->
      Alcotest.(check int) label expected actual
  | Observer.Delivery.Observer_never_delivered
  | Observer.Delivery.Observer_delivery_pending _
  | Observer.Delivery.Observer_delivery_running _ ->
      Alcotest.failf "%s: expected delivered observer state" label

let test_sent_finalizer_cannot_acknowledge_newer_delivery () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let old_update = changed ~old_value:0 ~new_value:1 in
  let new_update = changed ~old_value:1 ~new_value:2 in
  let live =
    {
      snapshot =
        Observer.Snapshot.create
          ~value:(Observer.Value.current 0)
          ~delivery:
            (Observer.Delivery.Observer_delivery_running
               (11, old_update, []));
      after_ack_count = 0;
    }
  in
  let port = make_delivery_port live in
  let sent_ack_attempts = ref 0 in
  let observer = () in
  let delivery =
    Delivery_handle.create ~token:11 ~update:old_update
      ~current_token:(fun () ->
        Effect.sync (fun () ->
            if Observer.running_delivery_token_matches port () observer 11 then
              Some 11
            else None))
      ~acknowledge_sent:(fun token update ->
        Effect.sync (fun () ->
            incr sent_ack_attempts;
            Observer.acknowledge_delivery port () observer token update
              ~after_ack:[]))
      ~acknowledge_drop:(fun ~after_ack:_ _token _update ->
        Effect.sync (fun () ->
            Alcotest.fail "sent path should not acknowledge a drop"))
  in
  let queue = make_queue 16 in
  let metrics = Bridge.create_metrics () in
  let hooks =
    Bridge.hooks ~metrics
      ~after_try_send_before_ack:(fun () ->
        Effect.sync (fun () ->
            live.snapshot <-
              Observer.Snapshot.with_delivery live.snapshot
                (Observer.Delivery.Observer_delivery_pending
                   (12, new_update, []))))
      ~on_closed_with_error:(fun _ -> Effect.unit)
      ()
  in
  run_ok runtime
    (Bridge.offer ~queue ~observer_delivery:delivery ~hooks ~on_drop:None);
  Alcotest.(check int) "sent acknowledgement was attempted" 1
    !sent_ack_attempts;
  Alcotest.(check int) "no stale after-ack hooks ran" 0
    live.after_ack_count;
  match Observer.Snapshot.delivery live.snapshot with
  | Observer.Delivery.Observer_delivery_pending (token, update, []) ->
      Alcotest.(check int) "newer pending token" 12 token;
      check_changed "newer pending update" ~old_value:1 ~new_value:2 update
  | Observer.Delivery.Observer_delivered _ ->
      Alcotest.fail "stale sent finalizer acknowledged newer delivery"
  | Observer.Delivery.Observer_never_delivered
  | Observer.Delivery.Observer_delivery_pending _
  | Observer.Delivery.Observer_delivery_running _ ->
      Alcotest.fail "expected newer pending delivery"

let test_sent_update_acknowledged_on_cancellation () =
  Eta_test.with_test_clock @@ fun sw _clock runtime ->
  let update = changed ~old_value:0 ~new_value:1 in
  let live =
    {
      snapshot =
        Observer.Snapshot.create
          ~value:(Observer.Value.current 0)
          ~delivery:
            (Observer.Delivery.Observer_delivery_running (11, update, []));
      after_ack_count = 0;
    }
  in
  let port = make_delivery_port live in
  let observer = () in
  let sent_ack_attempts = ref 0 in
  let delivery =
    Delivery_handle.create ~token:11 ~update
      ~current_token:(fun () ->
        Effect.sync (fun () ->
            if Observer.running_delivery_token_matches port () observer 11 then
              Some 11
            else None))
      ~acknowledge_sent:(fun token update ->
        Effect.sync (fun () ->
            incr sent_ack_attempts;
            Observer.acknowledge_delivery port () observer token update
              ~after_ack:[]))
      ~acknowledge_drop:(fun ~after_ack:_ _token _update ->
        Effect.sync (fun () ->
            Alcotest.fail "sent path should not acknowledge a drop"))
  in
  let sent, sent_resolver = Eio.Promise.create () in
  let release, release_resolver = Eio.Promise.create () in
  let hook_ran = ref false in
  let release_once =
    let released = ref false in
    fun () ->
      if not !released then (
        released := true;
        Eio.Promise.resolve release_resolver ())
  in
  let queue = make_queue 16 in
  let hooks =
    Bridge.hooks ~metrics:(Bridge.create_metrics ())
      ~after_try_send_before_ack:(fun () ->
        Effect.sync (fun () ->
            if not !hook_ran then (
              hook_ran := true;
              Eio.Promise.resolve sent_resolver ();
              Eio.Promise.await release)))
      ~on_closed_with_error:(fun _ -> Effect.unit)
      ()
  in
  Fun.protect ~finally:release_once @@ fun () ->
  let cancel_ctx = ref None in
  let offer =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Eta_eio.Runtime.run runtime
          (Bridge.offer ~queue ~observer_delivery:delivery ~hooks
             ~on_drop:None))
  in
  Eio.Promise.await sent;
  wait_until "sent offer cancellation context" (fun () ->
      Option.is_some !cancel_ctx);
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  release_once ();
  await_cancelled "sent offer" offer;
  Alcotest.(check int) "sent acknowledgement attempts" 1 !sent_ack_attempts;
  check_delivered "sent update delivered once" 1 live;
  match run_ok runtime (Eta.Queue.take_all queue) with
  | [ Observer.Update.Changed { old_value = 0; new_value = 1 } ] -> ()
  | [ _; _ ] -> Alcotest.fail "cancelled sent update was queued twice"
  | _ -> Alcotest.fail "expected one queued sent update"

let test_dropped_update_acknowledged_on_cancellation () =
  Eta_test.with_test_clock @@ fun sw _clock runtime ->
  let update = changed ~old_value:0 ~new_value:1 in
  let live =
    {
      snapshot =
        Observer.Snapshot.create
          ~value:(Observer.Value.current 0)
          ~delivery:
            (Observer.Delivery.Observer_delivery_running (11, update, []));
      after_ack_count = 0;
    }
  in
  let port = make_delivery_port live in
  let observer = () in
  let drop_ack_attempts = ref 0 in
  let delivery =
    Delivery_handle.create ~token:11 ~update
      ~current_token:(fun () ->
        Effect.sync (fun () ->
            if Observer.running_delivery_token_matches port () observer 11 then
              Some 11
            else None))
      ~acknowledge_sent:(fun _token _update ->
        Effect.sync (fun () ->
            Alcotest.fail "drop path should not acknowledge a sent update"))
      ~acknowledge_drop:(fun ~after_ack token update ->
        Effect.sync (fun () ->
            incr drop_ack_attempts;
            Observer.acknowledge_delivery port () observer token update
              ~after_ack))
  in
  let dropped, dropped_resolver = Eio.Promise.create () in
  let release, release_resolver = Eio.Promise.create () in
  let hook_ran = ref false in
  let release_once =
    let released = ref false in
    fun () ->
      if not !released then (
        released := true;
        Eio.Promise.resolve release_resolver ())
  in
  let queue = make_queue 1 in
  (match run_ok runtime (Eta.Queue.try_send queue (Observer.Update.Initialized 0)) with
  | `Sent -> ()
  | `Dropped | `Full | `Closed | `Closed_with_error _ ->
      Alcotest.fail "expected queue prefill to be sent");
  let drops = ref [] in
  let metrics = Bridge.create_metrics () in
  let hooks =
    Bridge.hooks ~metrics
      ~after_drop_before_ack:(fun () ->
        Effect.sync (fun () ->
            if not !hook_ran then (
              hook_ran := true;
              Eio.Promise.resolve dropped_resolver ();
              Eio.Promise.await release)))
      ~on_closed_with_error:(fun _ -> Effect.unit)
      ()
  in
  Fun.protect ~finally:release_once @@ fun () ->
  let cancel_ctx = ref None in
  let offer =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Eta_eio.Runtime.run runtime
          (Bridge.offer ~queue ~observer_delivery:delivery ~hooks
             ~on_drop:(Some (fun update -> drops := update :: !drops))))
  in
  Eio.Promise.await dropped;
  wait_until "dropped offer cancellation context" (fun () ->
      Option.is_some !cancel_ctx);
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  release_once ();
  await_cancelled "dropped offer" offer;
  Alcotest.(check int) "drop acknowledgement attempts" 1 !drop_ack_attempts;
  Alcotest.(check int) "drop metrics" 1 (Bridge.drop_count metrics);
  Alcotest.(check int) "after-ack hooks" 1 live.after_ack_count;
  check_delivered "dropped update delivered once" 1 live;
  match List.rev !drops with
  | [ Observer.Update.Changed { old_value = 0; new_value = 1 } ] -> ()
  | [ _; _ ] -> Alcotest.fail "cancelled dropped update ran on_drop twice"
  | _ -> Alcotest.fail "expected one dropped update callback"

let () =
  Alcotest.run "eta_signal_stream_bridge"
    [
      ( "stream_bridge",
        [
          Alcotest.test_case
            "sent finalizer cannot acknowledge newer delivery" `Quick
            test_sent_finalizer_cannot_acknowledge_newer_delivery;
          Alcotest.test_case "sent update acknowledged on cancellation" `Quick
            test_sent_update_acknowledged_on_cancellation;
          Alcotest.test_case "dropped update acknowledged on cancellation"
            `Quick test_dropped_update_acknowledged_on_cancellation;
        ] );
    ]
