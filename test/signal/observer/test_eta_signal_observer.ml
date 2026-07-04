module Observer = Eta_signal_observer

type after_ack =
  | Stored
  | Extra

let update_initialized = Observer.Update.Initialized 1
let update_changed = Observer.Update.Changed { old_value = 1; new_value = 2 }

let after_ack =
  Alcotest.testable
    (fun ppf -> function
      | Stored -> Format.pp_print_string ppf "stored"
      | Extra -> Format.pp_print_string ppf "extra")
    ( = )

let delivery =
  Alcotest.testable
    (fun ppf _ -> Format.pp_print_string ppf "<delivery>")
    ( = )

let test_update_delivered_value () =
  Alcotest.(check int) "initialized" 1
    (Observer.Update.delivered_value update_initialized);
  Alcotest.(check int) "changed" 2
    (Observer.Update.delivered_value update_changed)

let test_delivery_base_values () =
  let open Observer.Delivery in
  Alcotest.(check (option int)) "never" None
    (base Observer_never_delivered);
  Alcotest.(check (option int)) "delivered" (Some 1)
    (base (Observer_delivered 1));
  Alcotest.(check (option int)) "pending initialized" None
    (base (Observer_delivery_pending (1, update_initialized, [])));
  Alcotest.(check (option int)) "pending changed" (Some 1)
    (base (Observer_delivery_pending (1, update_changed, [])))

let test_delivery_claim_release_acknowledge () =
  let open Observer.Delivery in
  let state = Observer_delivery_pending (7, update_changed, [ Stored ]) in
  let running =
    match claim ~token:7 state with
    | Some state -> state
    | None -> Alcotest.fail "claim failed"
  in
  Alcotest.(check (option int)) "running token" (Some 7)
    (running_token running);
  let pending_state =
    match release ~token:7 running with
    | Some state -> state
    | None -> Alcotest.fail "release failed"
  in
  Alcotest.(check bool) "pending" true (pending pending_state);
  let delivered, actions =
    match
      acknowledge ~token:7 ~update:update_changed ~after_ack:[ Extra ]
        pending_state
    with
    | Some result -> result
    | None -> Alcotest.fail "acknowledge failed"
  in
  Alcotest.check delivery "delivered" (Observer_delivered 2) delivered;
  Alcotest.(check (list after_ack)) "actions" [ Extra; Stored ] actions

let test_delivery_ignores_stale_token () =
  let open Observer.Delivery in
  let state = Observer_delivery_pending (7, update_changed, []) in
  Alcotest.(check bool) "claim" true (Option.is_none (claim ~token:8 state));
  Alcotest.(check bool) "release" true
    (Option.is_none
       (release ~token:8
          (Observer_delivery_running (7, update_changed, []))));
  Alcotest.(check bool) "acknowledge" true
    (Option.is_none
       (acknowledge ~token:8 ~update:update_changed ~after_ack:[] state))

let () =
  Alcotest.run "eta_signal_observer"
    [
      ( "update",
        [
          Alcotest.test_case "delivered value" `Quick
            test_update_delivered_value;
        ] );
      ( "delivery",
        [
          Alcotest.test_case "base values" `Quick test_delivery_base_values;
          Alcotest.test_case "claim release acknowledge" `Quick
            test_delivery_claim_release_acknowledge;
          Alcotest.test_case "ignores stale token" `Quick
            test_delivery_ignores_stale_token;
        ] );
    ]
