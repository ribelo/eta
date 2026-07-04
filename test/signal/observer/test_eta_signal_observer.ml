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

let lifecycle_state =
  Alcotest.testable
    (fun ppf state ->
      Format.pp_print_string ppf (Observer.Lifecycle.label state))
    ( = )

let test_update_delivered_value () =
  Alcotest.(check int) "initialized" 1
    (Observer.Update.delivered_value update_initialized);
  Alcotest.(check int) "changed" 2
    (Observer.Update.delivered_value update_changed)

let test_value_read_and_label () =
  let open Observer.Value in
  Alcotest.(check string) "uninitialized label" "uninitialized"
    (label uninitialized);
  Alcotest.(check string) "current label" "current" (label (current 1));
  Alcotest.(check string) "failed label" "failed_without_current"
    (label Failed_without_current);
  Alcotest.(check int) "current read" 1
    (match read (current 1) with
    | Ok value -> value
    | Error _ -> Alcotest.fail "expected current value");
  (match read uninitialized with
  | Error `Uninitialized_observer -> ()
  | Ok _ | Error `No_current_value ->
      Alcotest.fail "expected uninitialized read error");
  (match read Failed_without_current with
  | Error `No_current_value -> ()
  | Ok _ | Error `Uninitialized_observer ->
      Alcotest.fail "expected no-current-value read error")

let test_value_mark_failed_without_current () =
  let open Observer.Value in
  Alcotest.(check bool) "uninitialized becomes failed" true
    (match mark_failed_without_current uninitialized with
    | Failed_without_current -> true
    | Uninitialized | Current _ -> false);
  Alcotest.(check bool) "current stays current" true
    (match mark_failed_without_current (current 1) with
    | Current 1 -> true
    | Uninitialized | Current _ | Failed_without_current -> false);
  Alcotest.(check bool) "failed stays failed" true
    (match mark_failed_without_current Failed_without_current with
    | Failed_without_current -> true
    | Uninitialized | Current _ -> false)

let test_value_unsafe_read_exn () =
  let open Observer.Value in
  Alcotest.(check int) "current" 1 (unsafe_read_exn (current 1));
  Alcotest.check_raises "uninitialized"
    (Invalid_argument "Eta_signal observer is not initialized") (fun () ->
      ignore (unsafe_read_exn uninitialized : int));
  Alcotest.check_raises "failed without current"
    (Invalid_argument "Eta_signal observer is not initialized") (fun () ->
      ignore (unsafe_read_exn Failed_without_current : int))

let test_lifecycle_predicates_and_labels () =
  let open Observer.Lifecycle in
  Alcotest.(check string) "registering label" "registering"
    (label (Registering "live"));
  Alcotest.(check string) "active label" "active" (label (Active "live"));
  Alcotest.(check string) "disposed label" "disposed" (label (Disposed 1));
  Alcotest.(check string) "invalid label" "invalid_scope"
    (label (Invalid_scope 1));
  Alcotest.(check (option string)) "registering live" (Some "live")
    (live (Registering "live"));
  Alcotest.(check (option string)) "active live" (Some "live")
    (active_live (Active "live"));
  Alcotest.(check bool) "registering demands" true
    (demands (Registering "live"));
  Alcotest.(check bool) "active demands" true (demands (Active "live"));
  Alcotest.(check bool) "disposed demand removed" false
    (demands (Disposed 1));
  Alcotest.(check bool) "invalid demand removed" false
    (demands (Invalid_scope 1));
  Alcotest.(check bool) "active predicate" true (active (Active "live"));
  Alcotest.(check bool) "registering inactive" false
    (active (Registering "live"))

let test_lifecycle_activate () =
  let open Observer.Lifecycle in
  Alcotest.check lifecycle_state "registering activates" (Active "live")
    (match activate (Registering "live") with
    | Ok state -> state
    | Error _ -> Alcotest.fail "expected activation");
  Alcotest.check lifecycle_state "active stays active" (Active "live")
    (match activate (Active "live") with
    | Ok state -> state
    | Error _ -> Alcotest.fail "expected active state");
  (match activate (Disposed 1) with
  | Error `Invalid_scope -> ()
  | Ok _ -> Alcotest.fail "expected disposed activation failure");
  match activate (Invalid_scope 1) with
  | Error `Invalid_scope -> ()
  | Ok _ -> Alcotest.fail "expected invalid-scope activation failure"

let test_lifecycle_finish () =
  let open Observer.Lifecycle in
  let value_of_live = String.length in
  let check_finish label expected_state expected_hook_live expected_remove
      finish =
    Alcotest.check lifecycle_state (label ^ " state") expected_state
      finish.state;
    Alcotest.(check (option string))
      (label ^ " hook live") expected_hook_live finish.hook_live;
    Alcotest.(check bool) (label ^ " remove") expected_remove finish.remove
  in
  check_finish "registering dispose" (Disposed 4) (Some "live") true
    (finish ~value_of_live Finish_disposed (Registering "live"));
  check_finish "active invalid" (Invalid_scope 4) (Some "live") false
    (finish ~value_of_live Finish_invalid_scope (Active "live"));
  check_finish "invalid dispose" (Disposed 4) None true
    (finish ~value_of_live Finish_disposed (Invalid_scope 4));
  check_finish "invalid invalid" (Invalid_scope 4) None false
    (finish ~value_of_live Finish_invalid_scope (Invalid_scope 4));
  check_finish "disposed invalid" (Disposed 4) None false
    (finish ~value_of_live Finish_invalid_scope (Disposed 4))

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
      ( "value",
        [
          Alcotest.test_case "read and label" `Quick test_value_read_and_label;
          Alcotest.test_case "mark failed without current" `Quick
            test_value_mark_failed_without_current;
          Alcotest.test_case "unsafe read exception" `Quick
            test_value_unsafe_read_exn;
        ] );
      ( "lifecycle",
        [
          Alcotest.test_case "predicates and labels" `Quick
            test_lifecycle_predicates_and_labels;
          Alcotest.test_case "activate" `Quick test_lifecycle_activate;
          Alcotest.test_case "finish" `Quick test_lifecycle_finish;
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
