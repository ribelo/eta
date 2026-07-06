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
  let queue =
    match Bridge.create_queue ~capacity:16 with
    | Ok queue -> queue
    | Error `Invalid_capacity -> Alcotest.fail "unexpected invalid capacity"
  in
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

let () =
  Alcotest.run "eta_signal_stream_bridge"
    [
      ( "stream_bridge",
        [
          Alcotest.test_case
            "sent finalizer cannot acknowledge newer delivery" `Quick
            test_sent_finalizer_cannot_acknowledge_newer_delivery;
        ] );
    ]
