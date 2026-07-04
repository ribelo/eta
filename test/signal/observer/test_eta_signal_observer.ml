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

let update =
  Alcotest.testable
    (fun ppf -> function
      | Observer.Update.Initialized value ->
          Format.fprintf ppf "Initialized %d" value
      | Observer.Update.Changed { old_value; new_value } ->
          Format.fprintf ppf "Changed { old_value = %d; new_value = %d }"
            old_value new_value)
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

let test_lifecycle_read_value () =
  let open Observer.Lifecycle in
  let read =
    read_value ~value_of_live:(fun value -> value)
  in
  Alcotest.(check int) "active current" 1
    (match read (Active (Observer.Value.current 1)) with
    | Ok value -> value
    | Error _ -> Alcotest.fail "expected current value");
  (match read (Registering Observer.Value.uninitialized) with
  | Error `Uninitialized_observer -> ()
  | Ok _ | Error (`Disposed_observer | `Invalid_scope | `No_current_value) ->
      Alcotest.fail "expected uninitialized observer");
  (match read (Disposed (Observer.Value.current 1)) with
  | Error `Disposed_observer -> ()
  | Ok _ | Error (`Invalid_scope | `No_current_value | `Uninitialized_observer)
    ->
      Alcotest.fail "expected disposed observer");
  (match read (Invalid_scope (Observer.Value.current 1)) with
  | Error `Invalid_scope -> ()
  | Ok _ | Error (`Disposed_observer | `No_current_value
                 | `Uninitialized_observer) ->
      Alcotest.fail "expected invalid scope");
  match read (Active Observer.Value.Failed_without_current) with
  | Error `No_current_value -> ()
  | Ok _ | Error (`Disposed_observer | `Invalid_scope | `Uninitialized_observer)
    ->
      Alcotest.fail "expected no current value"

let test_lifecycle_unsafe_read_value_exn () =
  let open Observer.Lifecycle in
  let read =
    unsafe_read_value_exn ~value_of_live:(fun value -> value)
  in
  Alcotest.(check int) "active current" 1
    (read (Active (Observer.Value.current 1)));
  Alcotest.check_raises "registering"
    (Invalid_argument
       "Eta_signal observer registration has not completed")
    (fun () -> ignore (read (Registering Observer.Value.uninitialized) : int));
  Alcotest.check_raises "disposed"
    (Invalid_argument "Eta_signal observer is disposed")
    (fun () -> ignore (read (Disposed (Observer.Value.current 1)) : int));
  Alcotest.check_raises "invalid scope"
    (Invalid_argument "Eta_signal observer scope is invalid")
    (fun () -> ignore (read (Invalid_scope (Observer.Value.current 1)) : int));
  Alcotest.check_raises "active missing value"
    (Invalid_argument "Eta_signal observer is not initialized")
    (fun () -> ignore (read (Active Observer.Value.uninitialized) : int))

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

let test_delivery_finish_running_acknowledges_or_releases () =
  let open Observer.Delivery in
  let running = Observer_delivery_running (7, update_changed, [ Stored ]) in
  (match
     finish_running ~token:7 ~update:update_changed ~delivered:true
       ~after_ack:[ Extra ] running
   with
  | Some (Finish_acknowledged (Observer_delivered 2, actions)) ->
      Alcotest.(check (list after_ack)) "ack actions" [ Extra; Stored ]
        actions
  | Some (Finish_acknowledged _ | Finish_released _) | None ->
      Alcotest.fail "expected acknowledged finish");
  match
    finish_running ~token:7 ~update:update_changed ~delivered:false
      ~after_ack:[ Extra ] running
  with
  | Some (Finish_released (Observer_delivery_pending (7, _, [ Stored ]))) ->
      ()
  | Some (Finish_acknowledged _ | Finish_released _) | None ->
      Alcotest.fail "expected released finish"

let test_delivery_ignores_stale_token () =
  let open Observer.Delivery in
  let state = Observer_delivery_pending (7, update_changed, []) in
  Alcotest.(check bool) "claim" true (Option.is_none (claim ~token:8 state));
  Alcotest.(check bool) "release" true
    (Option.is_none
       (release ~token:8
          (Observer_delivery_running (7, update_changed, []))));
  Alcotest.(check bool) "running token matches" true
    (running_token_matches ~token:7
       (Observer_delivery_running (7, update_changed, [])));
  Alcotest.(check bool) "running token mismatch" false
    (running_token_matches ~token:8
       (Observer_delivery_running (7, update_changed, [])));
  Alcotest.(check bool) "pending token does not match" false
    (running_token_matches ~token:7 state);
  Alcotest.(check bool) "acknowledge" true
    (Option.is_none
       (acknowledge ~token:8 ~update:update_changed ~after_ack:[] state))

let test_delivery_finish_ignores_stale_token () =
  let open Observer.Delivery in
  let running = Observer_delivery_running (7, update_changed, []) in
  Alcotest.(check bool) "delivered" true
    (Option.is_none
       (finish_running ~token:8 ~update:update_changed ~delivered:true
          ~after_ack:[] running));
  Alcotest.(check bool) "undelivered" true
    (Option.is_none
       (finish_running ~token:8 ~update:update_changed ~delivered:false
          ~after_ack:[] running))

let test_delivery_labels () =
  let open Observer.Delivery in
  Alcotest.(check string) "never" "never_delivered"
    (label Observer_never_delivered);
  Alcotest.(check string) "delivered" "delivered"
    (label (Observer_delivered 1));
  Alcotest.(check string) "pending" "pending"
    (label (Observer_delivery_pending (7, update_changed, [])));
  Alcotest.(check string) "running" "running"
    (label (Observer_delivery_running (7, update_changed, [])))

let test_snapshot_policy () =
  let initial = Observer.Snapshot.initial in
  Alcotest.(check string) "initial value" "uninitialized"
    (Observer.Value.label (Observer.Snapshot.value initial));
  Alcotest.(check string) "initial delivery" "never_delivered"
    (Observer.Delivery.label (Observer.Snapshot.delivery initial));
  let current =
    Observer.Snapshot.with_value initial (Observer.Value.current 1)
  in
  Alcotest.(check string) "current value" "current"
    (Observer.Value.label (Observer.Snapshot.value current));
  let pending =
    Observer.Delivery.pending_state ~token:1 update_initialized
  in
  let snapshot = Observer.Snapshot.with_delivery current pending in
  Alcotest.(check string) "pending delivery" "pending"
    (Observer.Delivery.label (Observer.Snapshot.delivery snapshot));
  let explicit =
    Observer.Snapshot.create ~value:(Observer.Value.current 2)
      ~delivery:(Observer.Delivery.Observer_delivered 2)
  in
  Alcotest.(check string) "explicit value" "current"
    (Observer.Value.label (Observer.Snapshot.value explicit));
  Alcotest.(check string) "explicit delivery" "delivered"
    (Observer.Delivery.label (Observer.Snapshot.delivery explicit))

let test_snapshot_delivery_transitions () =
  let initial = Observer.Snapshot.initial in
  let pending =
    Observer.Snapshot.with_pending_delivery ~token:1 update_initialized initial
  in
  Alcotest.(check string) "pending" "pending"
    (Observer.Delivery.label (Observer.Snapshot.delivery pending));
  let running =
    match Observer.Snapshot.claim_delivery ~token:1 pending with
    | Some snapshot -> snapshot
    | None -> Alcotest.fail "expected claim"
  in
  Alcotest.(check string) "running" "running"
    (Observer.Delivery.label (Observer.Snapshot.delivery running));
  Alcotest.(check bool) "running token" true
    (Observer.Snapshot.running_delivery_token_matches ~token:1 running);
  let pending_again =
    match Observer.Snapshot.release_delivery ~token:1 running with
    | Some snapshot -> snapshot
    | None -> Alcotest.fail "expected release"
  in
  Alcotest.(check string) "released" "pending"
    (Observer.Delivery.label (Observer.Snapshot.delivery pending_again));
  let running_again =
    match Observer.Snapshot.claim_delivery ~token:1 pending_again with
    | Some snapshot -> snapshot
    | None -> Alcotest.fail "expected second claim"
  in
  (match
     Observer.Snapshot.acknowledge_delivery ~token:1
       ~update:update_initialized ~after_ack:[ Extra ] running_again
   with
  | Some (snapshot, ack_actions) ->
      Alcotest.(check string) "acknowledged" "delivered"
        (Observer.Delivery.label (Observer.Snapshot.delivery snapshot));
      Alcotest.(check (list after_ack)) "ack actions" [ Extra ] ack_actions
  | None -> Alcotest.fail "expected acknowledge")

let test_snapshot_finish_running_delivery () =
  let running =
    Observer.Snapshot.create ~value:(Observer.Value.current 1)
      ~delivery:
        (Observer.Delivery.Observer_delivery_running
           (2, update_changed, [ Stored ]))
  in
  (match
     Observer.Snapshot.finish_running_delivery ~token:2 ~update:update_changed
       ~delivered:false ~after_ack:[ Extra ] running
   with
  | Some (Observer.Snapshot.Finish_released snapshot) ->
      Alcotest.(check string) "released" "pending"
        (Observer.Delivery.label (Observer.Snapshot.delivery snapshot))
  | Some (Observer.Snapshot.Finish_acknowledged _) | None ->
      Alcotest.fail "expected release");
  match
    Observer.Snapshot.finish_running_delivery ~token:2 ~update:update_changed
      ~delivered:true ~after_ack:[ Extra ] running
  with
  | Some (Observer.Snapshot.Finish_acknowledged (snapshot, ack_actions)) ->
      Alcotest.(check string) "acknowledged" "delivered"
        (Observer.Delivery.label (Observer.Snapshot.delivery snapshot));
      Alcotest.(check (list after_ack)) "ack actions"
        [ Extra; Stored ] ack_actions
  | Some (Observer.Snapshot.Finish_released _) | None ->
      Alcotest.fail "expected acknowledgement"

let test_snapshot_event_plan () =
  let initial = Observer.Snapshot.initial in
  let initialized =
    Observer.Snapshot.plan_event ~equal:Int.equal ~changed:true ~value:1
      initial
  in
  Alcotest.(check (option update)) "initialized update"
    (Some update_initialized) initialized.update;
  Alcotest.(check string) "initialized value" "current"
    (Observer.Value.label
       (Observer.Snapshot.value initialized.snapshot));
  let pending_equal =
    Observer.Snapshot.create ~value:(Observer.Value.current 1)
      ~delivery:
        (Observer.Delivery.Observer_delivery_pending
           (2, update_changed, []))
  in
  let suppressed =
    Observer.Snapshot.plan_event ~equal:Int.equal ~changed:false ~value:1
      pending_equal
  in
  Alcotest.(check (option update)) "suppressed update" None
    suppressed.update;
  Alcotest.(check string) "suppressed delivery" "delivered"
    (Observer.Delivery.label
       (Observer.Snapshot.delivery suppressed.snapshot))

let check_event_plan label ~expected_value ~expected_update ~expected_delivery
    plan =
  Alcotest.(check (option update)) (label ^ " update") expected_update
    plan.Observer.Event.update;
  Alcotest.(check (option delivery))
    (label ^ " delivery") expected_delivery plan.delivery;
  Alcotest.(check int)
    (label ^ " current value")
    expected_value
    (match plan.value with
    | Observer.Value.Current value -> value
    | Observer.Value.Uninitialized | Observer.Value.Failed_without_current ->
        Alcotest.fail "expected current observer value")

let test_event_plan_initializes_and_suppresses_unchanged () =
  let open Observer.Delivery in
  check_event_plan "initial"
    ~expected_value:1
    ~expected_update:(Some (Observer.Update.Initialized 1))
    ~expected_delivery:None
    (Observer.Event.plan ~equal:Int.equal ~changed:false ~value:1
       Observer_never_delivered);
  check_event_plan "unchanged"
    ~expected_value:1
    ~expected_update:None ~expected_delivery:None
    (Observer.Event.plan ~equal:Int.equal ~changed:false ~value:1
       (Observer_delivered 1))

let test_event_plan_changed_and_cutoff () =
  let open Observer.Delivery in
  check_event_plan "changed"
    ~expected_value:2
    ~expected_update:
      (Some (Observer.Update.Changed { old_value = 1; new_value = 2 }))
    ~expected_delivery:None
    (Observer.Event.plan ~equal:Int.equal ~changed:true ~value:2
       (Observer_delivered 1));
  check_event_plan "equal cutoff"
    ~expected_value:1
    ~expected_update:None
    ~expected_delivery:(Some (Observer_delivered 1))
    (Observer.Event.plan ~equal:Int.equal ~changed:true ~value:1
       (Observer_delivered 1))

let test_event_plan_pending_delivery () =
  let open Observer.Delivery in
  check_event_plan "pending changed"
    ~expected_value:2
    ~expected_update:
      (Some (Observer.Update.Changed { old_value = 1; new_value = 2 }))
    ~expected_delivery:None
    (Observer.Event.plan ~equal:Int.equal ~changed:false ~value:2
       (Observer_delivery_pending (7, update_changed, [])));
  check_event_plan "pending reverted"
    ~expected_value:1
    ~expected_update:None
    ~expected_delivery:(Some (Observer_delivered 1))
    (Observer.Event.plan ~equal:Int.equal ~changed:false ~value:1
       (Observer_delivery_pending (7, update_changed, [])))

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
          Alcotest.test_case "read value" `Quick test_lifecycle_read_value;
          Alcotest.test_case "unsafe read value" `Quick
            test_lifecycle_unsafe_read_value_exn;
        ] );
      ( "delivery",
        [
          Alcotest.test_case "base values" `Quick test_delivery_base_values;
          Alcotest.test_case "claim release acknowledge" `Quick
            test_delivery_claim_release_acknowledge;
          Alcotest.test_case "finish running" `Quick
            test_delivery_finish_running_acknowledges_or_releases;
          Alcotest.test_case "ignores stale token" `Quick
            test_delivery_ignores_stale_token;
          Alcotest.test_case "finish ignores stale token" `Quick
            test_delivery_finish_ignores_stale_token;
          Alcotest.test_case "labels" `Quick test_delivery_labels;
        ] );
      ( "snapshot",
        [
          Alcotest.test_case "policy" `Quick test_snapshot_policy;
          Alcotest.test_case "delivery transitions" `Quick
            test_snapshot_delivery_transitions;
          Alcotest.test_case "finish running delivery" `Quick
            test_snapshot_finish_running_delivery;
          Alcotest.test_case "event plan" `Quick
            test_snapshot_event_plan;
        ] );
      ( "event",
        [
          Alcotest.test_case "initializes and suppresses unchanged" `Quick
            test_event_plan_initializes_and_suppresses_unchanged;
          Alcotest.test_case "changed and cutoff" `Quick
            test_event_plan_changed_and_cutoff;
          Alcotest.test_case "pending delivery" `Quick
            test_event_plan_pending_delivery;
        ] );
    ]
