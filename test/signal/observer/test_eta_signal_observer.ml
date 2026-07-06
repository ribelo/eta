module Observer = Eta_signal_observer

type after_ack = unit

type live = { mutable snapshot : (int, after_ack) Observer.Snapshot.t }

type observer = {
  mutable state : (live, int Observer.Value.t) Observer.Lifecycle.t;
  mutable removed : bool;
}

type test_state = {
  mutable constructed : int;
  mutable callbacks : int;
  mutable after_ack : int;
}

let run_effect eff =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let runtime =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ()
  in
  Eta.Runtime.run runtime eff

let expect_effect_ok label eff =
  match run_effect eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error _ -> Alcotest.failf "%s: expected Ok" label

let live_snapshot live = live.snapshot
let set_live_snapshot live snapshot = live.snapshot <- snapshot

let lifecycle_port =
  Observer.lifecycle_port
    ~state:(fun observer -> observer.state)
    ~set_state:(fun observer state -> observer.state <- state)
    ~value:(fun live -> Observer.Snapshot.value live.snapshot)
    ~finish_hooks:(fun _live _reason -> [])
    ~remove:(fun observer -> observer.removed <- true)

let delivery_port test_state =
  Observer.delivery_port
    ~live:(fun () observer -> Observer.Lifecycle.active_live observer.state)
    ~snapshot:(fun () live -> live_snapshot live)
    ~set_snapshot:(fun () live snapshot -> set_live_snapshot live snapshot)
    ~run_after_ack:(fun () after_ack ->
      test_state.after_ack <- test_state.after_ack + List.length after_ack)

let access =
  Observer.delivery_event_access ~with_delivery_access:(fun f ->
      Eta.Effect.sync (fun () -> f ()))

let event_port test_state =
  let activation =
    Observer.delivery_event_activation_plan ~active:(fun () observer ->
        Observer.Lifecycle.active observer.state)
  in
  let callback =
    Observer.delivery_event_callback_plan
      ~construct:(fun () _observer _token update ->
        test_state.constructed <- test_state.constructed + 1;
        Ok (Some update))
      ~run_callback:(fun _observer _token _update ->
        Eta.Effect.sync (fun () ->
            test_state.callbacks <- test_state.callbacks + 1))
  in
  Observer.delivery_event_port ~activation ~callback

let create_observer () =
  let live =
    {
      snapshot =
        Observer.Snapshot.create
          ~value:(Observer.Value.current 0)
          ~delivery:Observer.Delivery.Observer_never_delivered;
    }
  in
  { state = Observer.Lifecycle.Active live; removed = false }

let delivery_event test_state observer ~token update =
  Observer.make_delivery_event ~access
    (delivery_port test_state)
    (event_port test_state) ~observer ~token update

let test_dispose_after_delivery_claim_skips_callback () =
  let test_state = { constructed = 0; callbacks = 0; after_ack = 0 } in
  let observer = create_observer () in
  let event =
    delivery_event test_state observer ~token:1
      (Observer.Update.Changed { old_value = 0; new_value = 1 })
  in
  Observer.Delivery_event.mark_pending () event;
  expect_effect_ok "delivery event"
    (Observer.Delivery_event.run
       ~after_claim:(fun () ->
         Eta.Effect.sync (fun () ->
             ignore
               (Observer.dispose_observer lifecycle_port observer
                 : after_ack list)))
       [ event ]);
  Alcotest.(check bool) "observer removed" true observer.removed;
  Alcotest.(check string) "observer state" "disposed"
    (Observer.Lifecycle.label observer.state);
  Alcotest.(check int) "callback not constructed" 0 test_state.constructed;
  Alcotest.(check int) "callback not run" 0 test_state.callbacks;
  Alcotest.(check int) "after-ack hooks not run" 0 test_state.after_ack

let () =
  Alcotest.run "eta_signal_observer"
    [
      ( "delivery",
        [
          Alcotest.test_case
            "dispose after delivery claim skips callback" `Quick
            test_dispose_after_delivery_claim_skips_callback;
        ] );
    ]
