module Observer = Eta_signal_observer

type test_error = [ `Delivery_failed ]

type after_ack =
  | Stored
  | Extra

let update_initialized = Observer.Update.Initialized 1
let update_changed = Observer.Update.Changed { old_value = 1; new_value = 2 }

let after_ack_testable =
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

let expect_delivery_failed label eff =
  match run_effect eff with
  | Eta.Exit.Error (Eta.Cause.Fail `Delivery_failed) -> ()
  | Eta.Exit.Error _ -> Alcotest.failf "%s: expected Delivery_failed" label
  | Eta.Exit.Ok _ -> Alcotest.failf "%s: expected failure" label

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

let test_lifecycle_diagnostic_visibility () =
  let open Observer.Lifecycle in
  Alcotest.(check bool) "active visible" true
    (diagnostic_visible ~include_invalid:false (Active "live"));
  Alcotest.(check bool) "registering hidden" false
    (diagnostic_visible ~include_invalid:true (Registering "live"));
  Alcotest.(check bool) "disposed hidden" false
    (diagnostic_visible ~include_invalid:true (Disposed 1));
  Alcotest.(check bool) "invalid predicate" true
    (invalid_scope (Invalid_scope 1));
  Alcotest.(check bool) "active not invalid" false
    (invalid_scope (Active "live"));
  Alcotest.(check bool) "invalid hidden when excluded" false
    (diagnostic_visible ~include_invalid:false (Invalid_scope 1));
  Alcotest.(check bool) "invalid visible when included" true
    (diagnostic_visible ~include_invalid:true (Invalid_scope 1))

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
    finish_result finish ~plan:(fun ~state ~hook_live ~remove ->
        Alcotest.check lifecycle_state (label ^ " state") expected_state
          state;
        Alcotest.(check (option string))
          (label ^ " hook live") expected_hook_live hook_live;
        Alcotest.(check bool) (label ^ " remove") expected_remove remove)
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
  Alcotest.(check (list after_ack_testable))
    "actions" [ Extra; Stored ] actions

let test_delivery_finish_running_acknowledges_or_releases () =
  let open Observer.Delivery in
  let running = Observer_delivery_running (7, update_changed, [ Stored ]) in
  (match
     finish_running ~token:7 ~update:update_changed ~delivered:true
       ~after_ack:[ Extra ] running
   with
  | Some finish ->
      finish_result finish
        ~acknowledged:(fun ~state ~after_ack ->
          Alcotest.check delivery "state" (Observer_delivered 2) state;
          Alcotest.(check (list after_ack_testable))
            "ack actions" [ Extra; Stored ] after_ack)
        ~released:(fun ~state:_ ->
          Alcotest.fail "expected acknowledged finish")
  | None -> Alcotest.fail "expected acknowledged finish");
  match
    finish_running ~token:7 ~update:update_changed ~delivered:false
      ~after_ack:[ Extra ] running
  with
  | Some finish ->
      finish_result finish
        ~acknowledged:(fun ~state:_ ~after_ack:_ ->
          Alcotest.fail "expected released finish")
        ~released:(fun ~state ->
          Alcotest.check delivery "state"
            (Observer_delivery_pending (7, update_changed, [ Stored ]))
            state)
  | None -> Alcotest.fail "expected released finish"

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

type model_update =
  | Model_initialized of int
  | Model_changed of {
      old_value : int;
      new_value : int;
    }

type model_delivery =
  | Model_never_delivered
  | Model_delivered of int
  | Model_pending of int * model_update * after_ack list
  | Model_running of int * model_update * after_ack list

type delivery_op =
  | Op_pending of int * model_update
  | Op_claim of int
  | Op_release of int
  | Op_acknowledge of int * model_update * after_ack list
  | Op_finish of int * model_update * bool * after_ack list
  | Op_running_token_matches of int

let observer_update_of_model = function
  | Model_initialized value -> Observer.Update.Initialized value
  | Model_changed { old_value; new_value } ->
      Observer.Update.Changed { old_value; new_value }

let delivered_model_value = function
  | Model_initialized value -> value
  | Model_changed { new_value; _ } -> new_value

let observer_delivery_of_model = function
  | Model_never_delivered -> Observer.Delivery.Observer_never_delivered
  | Model_delivered value -> Observer.Delivery.Observer_delivered value
  | Model_pending (token, update, after_ack) ->
      Observer.Delivery.Observer_delivery_pending
        (token, observer_update_of_model update, after_ack)
  | Model_running (token, update, after_ack) ->
      Observer.Delivery.Observer_delivery_running
        (token, observer_update_of_model update, after_ack)

let model_running_token = function
  | Model_running (token, _, _) -> Some token
  | Model_never_delivered | Model_delivered _ | Model_pending _ -> None

let model_claim token = function
  | Model_pending (pending_token, update, after_ack)
    when pending_token = token ->
      Some (Model_running (pending_token, update, after_ack))
  | Model_never_delivered | Model_delivered _ | Model_pending _
  | Model_running _ ->
      None

let model_release token = function
  | Model_running (running_token, update, after_ack)
    when running_token = token ->
      Some (Model_pending (token, update, after_ack))
  | Model_never_delivered | Model_delivered _ | Model_pending _
  | Model_running _ ->
      None

let model_acknowledge token update after_ack = function
  | Model_pending (pending_token, _, stored_after_ack)
  | Model_running (pending_token, _, stored_after_ack)
    when pending_token = token ->
      Some
        ( Model_delivered (delivered_model_value update),
          List.rev_append after_ack stored_after_ack )
  | Model_never_delivered | Model_delivered _ | Model_pending _
  | Model_running _ ->
      None

let model_finish token update delivered after_ack state =
  if delivered then
    match model_acknowledge token update after_ack state with
    | Some (state, actions) -> Some (`Ack (state, actions))
    | None -> None
  else
    match model_release token state with
    | Some state -> Some (`Release state)
    | None -> None

let model_update random =
  match Random.State.int random 3 with
  | 0 -> Model_initialized (Random.State.int random 20)
  | _ ->
      let old_value = Random.State.int random 20 in
      let new_value = Random.State.int random 20 in
      Model_changed { old_value; new_value }

let model_after_ack_list random =
  let rec loop acc = function
    | 0 -> acc
    | count ->
        let action =
          if Random.State.bool random then Stored else Extra
        in
        loop (action :: acc) (count - 1)
  in
  loop [] (Random.State.int random 3)

let delivery_op random =
  let token = Random.State.int random 4 in
  match Random.State.int random 6 with
  | 0 -> Op_pending (token, model_update random)
  | 1 -> Op_claim token
  | 2 -> Op_release token
  | 3 ->
      Op_acknowledge
        (token, model_update random, model_after_ack_list random)
  | 4 ->
      Op_finish
        ( token,
          model_update random,
          Random.State.bool random,
          model_after_ack_list random )
  | _ -> Op_running_token_matches token

let pp_model_update formatter = function
  | Model_initialized value -> Format.fprintf formatter "init(%d)" value
  | Model_changed { old_value; new_value } ->
      Format.fprintf formatter "changed(%d,%d)" old_value new_value

let pp_after_ack_list formatter actions =
  let pp_action formatter = function
    | Stored -> Format.pp_print_string formatter "stored"
    | Extra -> Format.pp_print_string formatter "extra"
  in
  Format.fprintf formatter "[%a]"
    (Format.pp_print_list
       ~pp_sep:(fun formatter () -> Format.pp_print_string formatter ";")
       pp_action)
    actions

let pp_delivery_op formatter = function
  | Op_pending (token, update) ->
      Format.fprintf formatter "pending(%d,%a)" token pp_model_update update
  | Op_claim token -> Format.fprintf formatter "claim(%d)" token
  | Op_release token -> Format.fprintf formatter "release(%d)" token
  | Op_acknowledge (token, update, actions) ->
      Format.fprintf formatter "ack(%d,%a,%a)" token pp_model_update update
        pp_after_ack_list actions
  | Op_finish (token, update, delivered, actions) ->
      Format.fprintf formatter "finish(%d,%a,%b,%a)" token pp_model_update
        update delivered pp_after_ack_list actions
  | Op_running_token_matches token ->
      Format.fprintf formatter "running_token_matches(%d)" token

let check_delivery_matches_model label expected actual =
  Alcotest.check delivery label (observer_delivery_of_model expected) actual

let check_delivery_trace_step label model_state actual_state step op =
  let step_label =
    Format.asprintf "%s step %d %a" label step pp_delivery_op op
  in
  match op with
  | Op_pending (token, update) ->
      let next_model = Model_pending (token, update, []) in
      let next_actual =
        Observer.Delivery.pending_state ~token
          (observer_update_of_model update)
      in
      (next_model, next_actual)
  | Op_claim token ->
      let model_result = model_claim token model_state in
      let actual_result = Observer.Delivery.claim ~token actual_state in
      Alcotest.(check bool)
        (step_label ^ " claim result")
        (Option.is_some model_result)
        (Option.is_some actual_result);
      ( Option.value model_result ~default:model_state,
        Option.value actual_result ~default:actual_state )
  | Op_release token ->
      let model_result = model_release token model_state in
      let actual_result = Observer.Delivery.release ~token actual_state in
      Alcotest.(check bool)
        (step_label ^ " release result")
        (Option.is_some model_result)
        (Option.is_some actual_result);
      ( Option.value model_result ~default:model_state,
        Option.value actual_result ~default:actual_state )
  | Op_acknowledge (token, update, after_ack) ->
      let model_result =
        model_acknowledge token update after_ack model_state
      in
      let actual_result =
        Observer.Delivery.acknowledge ~token
          ~update:(observer_update_of_model update) ~after_ack actual_state
      in
      Alcotest.(check bool)
        (step_label ^ " ack result")
        (Option.is_some model_result)
        (Option.is_some actual_result);
      (match (model_result, actual_result) with
      | Some (model_state, model_actions), Some (actual_state, actual_actions)
        ->
          Alcotest.(check (list after_ack_testable))
            (step_label ^ " ack actions") model_actions actual_actions;
          (model_state, actual_state)
      | None, None -> (model_state, actual_state)
      | Some _, None | None, Some _ ->
          Alcotest.failf "%s: inconsistent ack result" step_label)
  | Op_finish (token, update, delivered, after_ack) ->
      let model_result =
        model_finish token update delivered after_ack model_state
      in
      let actual_result =
        Observer.Delivery.finish_running ~token
          ~update:(observer_update_of_model update) ~delivered ~after_ack
          actual_state
      in
      Alcotest.(check bool)
        (step_label ^ " finish result")
        (Option.is_some model_result)
        (Option.is_some actual_result);
      (match (model_result, actual_result) with
      | Some (`Ack (model_state, model_actions)), Some finish ->
          Observer.Delivery.finish_result finish
            ~acknowledged:(fun ~state:actual_state ~after_ack:actual_actions ->
              Alcotest.(check (list after_ack_testable))
                (step_label ^ " finish actions") model_actions
                actual_actions;
              (model_state, actual_state))
            ~released:(fun ~state:_ ->
              Alcotest.failf "%s: inconsistent finish result" step_label)
      | Some (`Release model_state), Some finish ->
          Observer.Delivery.finish_result finish
            ~acknowledged:(fun ~state:_ ~after_ack:_ ->
              Alcotest.failf "%s: inconsistent finish result" step_label)
            ~released:(fun ~state:actual_state ->
              (model_state, actual_state))
      | None, None -> (model_state, actual_state)
      | _ -> Alcotest.failf "%s: inconsistent finish result" step_label)
  | Op_running_token_matches token ->
      Alcotest.(check bool)
        (step_label ^ " running token matches")
        (match model_running_token model_state with
        | Some running_token -> running_token = token
        | None -> false)
        (Observer.Delivery.running_token_matches ~token actual_state);
      (model_state, actual_state)

let run_delivery_generated_trace seed =
  let label = Format.asprintf "delivery-seed-%d" seed in
  let random = Random.State.make [| seed |] in
  let rec loop model_state actual_state step =
    check_delivery_matches_model
      (Format.asprintf "%s before %d" label step)
      model_state actual_state;
    if step = 150 then ()
    else
      let op = delivery_op random in
      let model_state, actual_state =
        check_delivery_trace_step label model_state actual_state step op
      in
      loop model_state actual_state (step + 1)
  in
  loop Model_never_delivered Observer.Delivery.Observer_never_delivered 0

let test_delivery_generated_traces_match_model () =
  List.iter run_delivery_generated_trace
    [ 1; 2; 3; 5; 8; 13; 21; 34; 55; 89 ]

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

let record events event = events := !events @ [ event ]

let finish_reason_label = function
  | Observer.Lifecycle.Finish_disposed -> "disposed"
  | Observer.Lifecycle.Finish_invalid_scope -> "invalid_scope"

let test_lifecycle_port_owns_activation_finish_and_removal () =
  let events = ref [] in
  let state =
    ref
      (Observer.Lifecycle.Registering "live"
        : (string, int Observer.Value.t) Observer.Lifecycle.t)
  in
  let removed = ref false in
  let port =
    Observer.lifecycle_port ~state:(fun _observer -> !state)
      ~set_state:(fun _observer next ->
        state := next;
        record events ("state:" ^ Observer.Lifecycle.label next))
      ~value:(fun live -> Observer.Value.current (String.length live))
      ~finish_hooks:(fun live reason ->
        [
          (fun () ->
            record events
              ("hook:" ^ live ^ ":" ^ finish_reason_label reason));
        ])
      ~remove:(fun _observer ->
        removed := true;
        record events "remove")
  in
  (match Observer.activate_observer port "observer" with
  | Ok _ -> ()
  | Error `Invalid_scope -> Alcotest.fail "expected activation");
  (match !state with
  | Observer.Lifecycle.Active "live" -> ()
  | _ -> Alcotest.fail "expected active observer");
  let hooks = Observer.invalidate_observer port "observer" in
  (match !state with
  | Observer.Lifecycle.Invalid_scope (Observer.Value.Current 4) -> ()
  | _ -> Alcotest.fail "expected invalid observer");
  Alcotest.(check bool) "invalidated observer retained" false !removed;
  List.iter (fun hook -> hook ()) hooks;
  let hooks = Observer.dispose_observer port "observer" in
  (match !state with
  | Observer.Lifecycle.Disposed (Observer.Value.Current 4) -> ()
  | _ -> Alcotest.fail "expected disposed observer");
  Alcotest.(check int) "disposed invalid observer has no hook" 0
    (List.length hooks);
  Alcotest.(check bool) "disposed observer removed" true !removed;
  Alcotest.(check (list string))
    "events"
    [
      "state:active";
      "state:invalid_scope";
      "hook:live:invalid_scope";
      "state:disposed";
      "remove";
    ]
    !events

let test_delivery_port_marks_failed_without_current () =
  let snapshot : (int, after_ack) Observer.Snapshot.t ref =
    ref Observer.Snapshot.initial
  in
  let port =
    Observer.delivery_port ~live:(fun () () -> Some ())
      ~snapshot:(fun () () -> !snapshot)
      ~set_snapshot:(fun () () next -> snapshot := next)
      ~run_after_ack:(fun () _actions -> ())
  in
  Observer.mark_failed_without_current port () ();
  (match Observer.Value.read (Observer.Snapshot.value !snapshot) with
  | Error `No_current_value -> ()
  | Ok _ | Error `Uninitialized_observer ->
      Alcotest.fail "expected no current value");
  snapshot :=
    Observer.Snapshot.create ~value:(Observer.Value.current 7)
      ~delivery:Observer.Delivery.Observer_never_delivered;
  Observer.mark_failed_without_current port () ();
  Alcotest.(check int) "current value preserved" 7
    (match Observer.Value.read (Observer.Snapshot.value !snapshot) with
    | Ok value -> value
    | Error _ -> Alcotest.fail "expected current value")

type observer_live = {
  mutable snapshot : (int, after_ack) Observer.Snapshot.t;
}

type observer_ref = { mutable live : observer_live option }

let observer_capability = "observer-capability"

let check_observer_capability capability =
  Alcotest.(check string) "observer capability" observer_capability capability

let test_collect_event_stages_snapshot_and_constructs_event () =
  let events = ref [] in
  let live =
    {
      snapshot =
        Observer.Snapshot.create ~value:Observer.Value.uninitialized
          ~delivery:Observer.Delivery.Observer_never_delivered;
    }
  in
  let observer = { live = Some live } in
  let port =
    Observer.collection_port
      ~live:(fun capability observer ->
        check_observer_capability capability;
        observer.live)
      ~skip:(fun capability _observer ->
        check_observer_capability capability;
        false)
      ~compute:(fun capability _observer ->
        check_observer_capability capability;
        record events "compute";
        (1, true))
      ~snapshot:(fun capability live ->
        check_observer_capability capability;
        live.snapshot)
      ~stage_snapshot:(fun capability live snapshot ->
        check_observer_capability capability;
        live.snapshot <- snapshot;
        record events
          ("stage:"
          ^ Observer.Value.label (Observer.Snapshot.value snapshot)))
      ~equal:(fun _observer -> Int.equal)
      ~make_event:(fun capability _observer update ->
        check_observer_capability capability;
        record events "event";
        update)
  in
  Alcotest.(check (option update))
    "event" (Some (Observer.Update.Initialized 1))
    (Observer.collect_event port observer_capability observer);
  Alcotest.(check string) "snapshot value" "current"
    (Observer.Value.label (Observer.Snapshot.value live.snapshot));
  Alcotest.(check (list string))
    "events" [ "compute"; "stage:current"; "event" ] !events

let test_collect_event_skips_inactive_and_invalidated_observers () =
  let events = ref [] in
  let live =
    {
      snapshot =
        Observer.Snapshot.create ~value:(Observer.Value.current 1)
          ~delivery:(Observer.Delivery.Observer_delivered 1);
    }
  in
  let inactive = { live = None } in
  let skipped = { live = Some live } in
  let port =
    Observer.collection_port
      ~live:(fun _capability observer -> observer.live)
      ~skip:(fun _capability observer -> observer == skipped)
      ~compute:(fun _capability _observer ->
        record events "compute";
        (2, true))
      ~snapshot:(fun _capability live -> live.snapshot)
      ~stage_snapshot:(fun _capability live snapshot ->
        live.snapshot <- snapshot;
        record events "stage")
      ~equal:(fun _observer -> Int.equal)
      ~make_event:(fun _capability _observer update ->
        record events "event";
        update)
  in
  Alcotest.(check (option update)) "inactive" None
    (Observer.collect_event port observer_capability inactive);
  Alcotest.(check (option update)) "invalidated" None
    (Observer.collect_event port observer_capability skipped);
  Alcotest.(check (list string)) "no collection work" [] !events

let delivery_runner_ops ?(active = fun _ -> true) ?(claim = fun _ -> true)
    ?(construct = fun event -> Some ("callback:" ^ event))
    ?(run_callback = fun _event _callback -> Ok ())
    ?(acknowledge = fun _event -> Ok ()) events =
  let effect value = Eta.Effect.sync (fun () -> value) in
  Observer.Delivery_runner.create
    ~active:(fun event ->
      effect
        (record events ("active:" ^ event);
         active event))
    ~claim:(fun event ->
      effect
        (record events ("claim:" ^ event);
         claim event))
    ~after_claim:(fun () -> effect (record events "after_claim"))
    ~construct:(fun event ->
      effect
        (record events ("construct:" ^ event);
         construct event))
    ~run_callback:(fun event callback ->
      match run_callback event callback with
      | Ok () -> effect (record events ("run:" ^ event ^ ":" ^ callback))
      | Error `Delivery_failed ->
          Eta.Effect.sync (fun () ->
              record events ("run:" ^ event ^ ":" ^ callback))
          |> Eta.Effect.bind (fun () -> Eta.Effect.fail `Delivery_failed))
    ~acknowledge:(fun event ->
      match acknowledge event with
      | Ok () -> effect (record events ("ack:" ^ event))
      | Error `Delivery_failed ->
          Eta.Effect.sync (fun () -> record events ("ack:" ^ event))
          |> Eta.Effect.bind (fun () -> Eta.Effect.fail `Delivery_failed))
    ~finish_error:(fun event ~delivered ->
      effect
        (record events
           ("finish_error:" ^ event ^ ":" ^ string_of_bool delivered)))

let test_delivery_runner_orders_claimed_events () =
  let events = ref [] in
  let ops =
    delivery_runner_ops
      ~active:(fun event -> event <> "inactive")
      ~claim:(fun event -> event <> "unclaimed")
      ~construct:(fun event ->
        if event = "no-callback" then None else Some ("callback:" ^ event))
      events
  in
  expect_effect_ok "runner"
    (Observer.Delivery_runner.run ops
       [ "first"; "inactive"; "unclaimed"; "no-callback"; "second" ]);
  Alcotest.(check (list string))
    "events"
    [
      "active:first";
      "claim:first";
      "after_claim";
      "construct:first";
      "run:first:callback:first";
      "ack:first";
      "active:inactive";
      "active:unclaimed";
      "claim:unclaimed";
      "active:no-callback";
      "claim:no-callback";
      "after_claim";
      "construct:no-callback";
      "active:second";
      "claim:second";
      "after_claim";
      "construct:second";
      "run:second:callback:second";
      "ack:second";
    ]
    !events

let test_delivery_runner_releases_claim_on_failure () =
  let events = ref [] in
  let ops =
    delivery_runner_ops
      ~run_callback:(fun event _callback ->
        if event = "first" then Error `Delivery_failed else Ok ())
      events
  in
  expect_delivery_failed "runner failure"
    (Observer.Delivery_runner.run ops [ "first"; "second" ]);
  Alcotest.(check (list string))
    "events"
    [
      "active:first";
      "claim:first";
      "after_claim";
      "construct:first";
      "run:first:callback:first";
      "finish_error:first:false";
    ]
    !events

let test_delivery_runner_finishes_acknowledged_failure_as_delivered () =
  let events = ref [] in
  let ops =
    delivery_runner_ops
      ~acknowledge:(fun event ->
        if event = "first" then Error `Delivery_failed else Ok ())
      events
  in
  expect_delivery_failed "acknowledge failure"
    (Observer.Delivery_runner.run ops [ "first"; "second" ]);
  Alcotest.(check (list string))
    "events"
    [
      "active:first";
      "claim:first";
      "after_claim";
      "construct:first";
      "run:first:callback:first";
      "ack:first";
      "finish_error:first:true";
    ]
    !events

let delivery_event ?(active = fun _ -> true) ?(claim = fun _ -> true)
    ?(construct = fun event -> Some ("callback:" ^ event))
    ?(run_callback = fun _event _callback -> Ok ())
    ?(acknowledge = fun _event -> Ok ()) events name =
  let effect value = Eta.Effect.sync (fun () -> value) in
  Observer.Delivery_event.create
    ~mark_pending:(fun () -> record events ("mark:" ^ name))
    ~active:(fun () ->
      effect
        (record events ("active:" ^ name);
         active name))
    ~claim:(fun () ->
      effect
        (record events ("claim:" ^ name);
         claim name))
    ~construct:(fun () ->
      effect
        (record events ("construct:" ^ name);
         construct name))
    ~run_callback:(fun callback ->
      match run_callback name callback with
      | Ok () -> effect (record events ("run:" ^ name ^ ":" ^ callback))
      | Error `Delivery_failed ->
          Eta.Effect.sync (fun () ->
              record events ("run:" ^ name ^ ":" ^ callback))
          |> Eta.Effect.bind (fun () -> Eta.Effect.fail `Delivery_failed))
    ~acknowledge:(fun () ->
      match acknowledge name with
      | Ok () -> effect (record events ("ack:" ^ name))
      | Error `Delivery_failed ->
          Eta.Effect.sync (fun () -> record events ("ack:" ^ name))
          |> Eta.Effect.bind (fun () -> Eta.Effect.fail `Delivery_failed))
    ~finish_error:(fun ~delivered ->
      effect
        (record events
           ("finish_error:" ^ name ^ ":" ^ string_of_bool delivered)))

let test_delivery_event_collection_marks_pending () =
  let events = ref [] in
  let first = "first" in
  let second = "second" in
  let inactive = "inactive" in
  let rank observer =
    if String.equal observer first then 0 else 1
  in
  let collection =
    Observer.delivery_event_collection
      ~active:(fun observer -> not (String.equal observer inactive))
      ~compare:(fun left right -> Int.compare (rank left) (rank right))
      ~collect_event:(fun () observer ->
        record events ("collect:" ^ observer);
        Some (delivery_event events observer))
  in
  let active =
    Observer.active_delivery_observers collection [ second; inactive; first ]
  in
  Alcotest.(check (list string))
    "active observers" [ second; first ] active;
  let delivery_events = Observer.collect_delivery_events collection () active in
  Observer.mark_delivery_events_pending collection () delivery_events;
  Alcotest.(check (list string))
    "events"
    [
      "collect:first";
      "collect:second";
      "mark:first";
      "mark:second";
    ]
    !events

let test_delivery_event_marks_and_runs_claimed_events () =
  let events = ref [] in
  let first = delivery_event events "first" in
  let inactive =
    delivery_event ~active:(fun event -> event <> "inactive") events
      "inactive"
  in
  let unclaimed =
    delivery_event ~claim:(fun event -> event <> "unclaimed") events
      "unclaimed"
  in
  let no_callback =
    delivery_event
      ~construct:(fun event ->
        if event = "no-callback" then None else Some ("callback:" ^ event))
      events "no-callback"
  in
  let second = delivery_event events "second" in
  Observer.Delivery_event.mark_pending () first;
  expect_effect_ok "delivery events"
    (Observer.Delivery_event.run
       ~after_claim:(fun () ->
         Eta.Effect.sync (fun () -> record events "after_claim"))
       [ first; inactive; unclaimed; no_callback; second ]);
  Alcotest.(check (list string))
    "events"
    [
      "mark:first";
      "active:first";
      "claim:first";
      "after_claim";
      "construct:first";
      "run:first:callback:first";
      "ack:first";
      "active:inactive";
      "active:unclaimed";
      "claim:unclaimed";
      "active:no-callback";
      "claim:no-callback";
      "after_claim";
      "construct:no-callback";
      "active:second";
      "claim:second";
      "after_claim";
      "construct:second";
      "run:second:callback:second";
      "ack:second";
    ]
    !events

let test_delivery_event_finishes_error () =
  let events = ref [] in
  let first =
    delivery_event
      ~run_callback:(fun event _callback ->
        if event = "first" then Error `Delivery_failed else Ok ())
      events "first"
  in
  let second = delivery_event events "second" in
  expect_delivery_failed "delivery event failure"
    (Observer.Delivery_event.run
       ~after_claim:(fun () ->
         Eta.Effect.sync (fun () -> record events "after_claim"))
       [ first; second ]);
  Alcotest.(check (list string))
    "events"
    [
      "active:first";
      "claim:first";
      "after_claim";
      "construct:first";
      "run:first:callback:first";
      "finish_error:first:false";
    ]
    !events

let test_delivery_handle_accessors () =
  let handle =
    Observer.Delivery_handle.create ~token:7 ~update:update_changed
      ~current_token:(fun () -> Eta.Effect.pure (Some 7))
      ~acknowledge_sent:(fun _token _update -> Eta.Effect.unit)
      ~acknowledge_drop:(fun ~after_ack:_ _token _update -> Eta.Effect.unit)
  in
  Alcotest.(check int) "token" 7
    (Observer.Delivery_handle.token handle);
  Alcotest.check update "update" update_changed
    (Observer.Delivery_handle.update handle);
  ignore
    (Observer.Delivery_handle.current_token handle
      : unit -> (int option, [ `Any ]) Eta.Effect.t);
  ignore
    (Observer.Delivery_handle.acknowledge_sent handle
      : int -> int Observer.Update.t -> (unit, [ `Any ]) Eta.Effect.t);
  ignore
    (Observer.Delivery_handle.acknowledge_drop handle
      : after_ack:after_ack list ->
        int ->
        int Observer.Update.t ->
        (unit, [ `Any ]) Eta.Effect.t)

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
      Alcotest.(check (list after_ack_testable))
        "ack actions" [ Extra ] ack_actions
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
  | Some finish ->
      Observer.Snapshot.finish_result finish
        ~acknowledged:(fun ~snapshot:_ ~after_ack:_ ->
          Alcotest.fail "expected release")
        ~released:(fun ~snapshot ->
          Alcotest.(check string) "released" "pending"
            (Observer.Delivery.label (Observer.Snapshot.delivery snapshot)))
  | None -> Alcotest.fail "expected release");
  match
    Observer.Snapshot.finish_running_delivery ~token:2 ~update:update_changed
      ~delivered:true ~after_ack:[ Extra ] running
  with
  | Some finish ->
      Observer.Snapshot.finish_result finish
        ~acknowledged:(fun ~snapshot ~after_ack ->
          Alcotest.(check string) "acknowledged" "delivered"
            (Observer.Delivery.label (Observer.Snapshot.delivery snapshot));
          Alcotest.(check (list after_ack_testable))
            "ack actions"
            [ Extra; Stored ] after_ack)
        ~released:(fun ~snapshot:_ ->
          Alcotest.fail "expected acknowledgement")
  | None -> Alcotest.fail "expected acknowledgement"

let observer_delivery_port events =
  Observer.delivery_port
    ~live:(fun capability observer ->
      check_observer_capability capability;
      observer.live)
    ~snapshot:(fun capability live ->
      check_observer_capability capability;
      live.snapshot)
    ~set_snapshot:(fun capability live snapshot ->
      check_observer_capability capability;
      live.snapshot <- snapshot;
      record events
        ("set:"
        ^ Observer.Delivery.label (Observer.Snapshot.delivery snapshot)))
    ~run_after_ack:(fun capability actions ->
      check_observer_capability capability;
      List.iter
        (fun action ->
          record events
            (match action with
            | Stored -> "after_ack:stored"
            | Extra -> "after_ack:extra"))
        actions)

let test_delivery_port_claim_acknowledge_and_finish () =
  let events = ref [] in
  let live =
    {
      snapshot =
        Observer.Snapshot.create ~value:(Observer.Value.current 1)
          ~delivery:
            (Observer.Delivery.Observer_delivery_pending
               (7, update_changed, [ Stored ]));
    }
  in
  let observer = { live = Some live } in
  let port = observer_delivery_port events in
  Alcotest.(check bool) "claim" true
    (Observer.claim_delivery port observer_capability observer 7);
  Alcotest.(check bool) "running token" true
    (Observer.running_delivery_token_matches port observer_capability observer
       7);
  Observer.acknowledge_delivery port observer_capability observer 7 update_changed
    ~after_ack:[ Extra ];
  Alcotest.(check string) "acknowledged" "delivered"
    (Observer.Delivery.label (Observer.Snapshot.delivery live.snapshot));
  Alcotest.(check (list string))
    "ack events"
    [
      "set:running";
      "set:delivered";
      "after_ack:extra";
      "after_ack:stored";
    ]
    !events;
  events := [];
  live.snapshot <-
    Observer.Snapshot.create ~value:(Observer.Value.current 1)
      ~delivery:
        (Observer.Delivery.Observer_delivery_running
           (8, update_changed, [ Stored ]));
  Observer.finish_delivery_after_error port observer_capability observer 8
    update_changed ~delivered:false;
  Alcotest.(check string) "released" "pending"
    (Observer.Delivery.label (Observer.Snapshot.delivery live.snapshot));
  Alcotest.(check (list string)) "release events" [ "set:pending" ]
    !events

let test_delivery_port_ignores_missing_or_stale_delivery () =
  let events = ref [] in
  let live =
    {
      snapshot =
        Observer.Snapshot.create ~value:(Observer.Value.current 1)
          ~delivery:
            (Observer.Delivery.Observer_delivery_pending
               (7, update_changed, []));
    }
  in
  let observer = { live = Some live } in
  let inactive = { live = None } in
  let port = observer_delivery_port events in
  Alcotest.(check bool) "stale claim" false
    (Observer.claim_delivery port observer_capability observer 8);
  Observer.acknowledge_delivery port observer_capability observer 8 update_changed
    ~after_ack:[ Extra ];
  Observer.finish_delivery_after_error port observer_capability observer 8
    update_changed ~delivered:true;
  Alcotest.(check bool) "inactive running token" false
    (Observer.running_delivery_token_matches port observer_capability inactive
       7);
  Alcotest.(check (list string)) "no events" [] !events;
  Alcotest.(check string) "state unchanged" "pending"
    (Observer.Delivery.label (Observer.Snapshot.delivery live.snapshot))

let observer_event_port ?(run_callback = fun _observer _token _callback ->
    Eta.Effect.unit) events =
  Observer.delivery_event_port
    ~active:(fun capability observer ->
      check_observer_capability capability;
      record events "active";
      Option.is_some observer.live)
    ~construct:(fun capability _observer token _update ->
      check_observer_capability capability;
      record events ("construct:" ^ string_of_int token);
      Ok (Some "callback"))
    ~run_callback:(fun observer token callback ->
      Eta.Effect.sync (fun () ->
          record events ("run:" ^ string_of_int token ^ ":" ^ callback))
      |> Eta.Effect.bind (fun () -> run_callback observer token callback))

let observer_event_access events =
  Observer.delivery_event_access ~with_delivery_access:(fun f ->
      Eta.Effect.sync (fun () ->
          record events "access";
          f observer_capability))

let test_make_delivery_handle_owns_token_and_acknowledge () =
  let events = ref [] in
  let live =
    {
      snapshot =
        Observer.Snapshot.create ~value:(Observer.Value.current 1)
          ~delivery:
            (Observer.Delivery.Observer_delivery_running
               (7, update_changed, [ Stored ]));
    }
  in
  let observer = { live = Some live } in
  let handle =
    Observer.make_delivery_handle ~access:(observer_event_access events)
      (observer_delivery_port events) ~observer ~token:7 update_changed
  in
  Alcotest.(check (option int)) "current token" (Some 7)
    (expect_effect_ok "handle current token"
       (Observer.Delivery_handle.current_token handle ()));
  Alcotest.(check (list string)) "current token events" [ "access" ] !events;
  events := [];
  expect_effect_ok "handle sent"
    (Observer.Delivery_handle.acknowledge_sent handle 7 update_changed);
  Alcotest.(check string) "sent delivered" "delivered"
    (Observer.Delivery.label (Observer.Snapshot.delivery live.snapshot));
  Alcotest.(check (list string))
    "sent events"
    [ "access"; "set:delivered"; "after_ack:stored" ]
    !events;
  events := [];
  live.snapshot <-
    Observer.Snapshot.create ~value:(Observer.Value.current 1)
      ~delivery:
        (Observer.Delivery.Observer_delivery_running
           (8, update_changed, [ Stored ]));
  let drop_handle =
    Observer.make_delivery_handle ~access:(observer_event_access events)
      (observer_delivery_port events) ~observer ~token:8 update_changed
  in
  expect_effect_ok "handle drop"
    (Observer.Delivery_handle.acknowledge_drop drop_handle
       ~after_ack:[ Extra ] 8 update_changed);
  Alcotest.(check (list string))
    "drop events"
    [
      "access";
      "set:delivered";
      "after_ack:extra";
      "after_ack:stored";
    ]
    !events;
  events := [];
  Alcotest.(check (option int)) "stale current token" None
    (expect_effect_ok "handle stale current token"
       (Observer.Delivery_handle.current_token drop_handle ()));
  Alcotest.(check (list string)) "stale events" [ "access" ] !events

let test_make_delivery_event_owns_success_transitions () =
  let events = ref [] in
  let live =
    {
      snapshot =
        Observer.Snapshot.create ~value:(Observer.Value.current 1)
          ~delivery:
            (Observer.Delivery.Observer_delivery_pending
               (7, update_changed, [ Stored ]));
    }
  in
  let observer = { live = Some live } in
  let event =
    Observer.make_delivery_event ~access:(observer_event_access events)
      (observer_delivery_port events)
      (observer_event_port events) ~observer ~token:7 update_changed
  in
  Observer.Delivery_event.mark_pending observer_capability event;
  expect_effect_ok "delivery event success"
    (Observer.Delivery_event.run
       ~after_claim:(fun () ->
         Eta.Effect.sync (fun () -> record events "after_claim"))
       [ event ]);
  Alcotest.(check string) "delivered" "delivered"
    (Observer.Delivery.label (Observer.Snapshot.delivery live.snapshot));
  Alcotest.(check (list string))
    "events"
    [
      "set:pending";
      "access";
      "active";
      "access";
      "set:running";
      "after_claim";
      "access";
      "construct:7";
      "access";
      "run:7:callback";
      "access";
      "set:delivered";
    ]
    !events

let test_make_delivery_event_releases_claim_on_failure () =
  let events = ref [] in
  let live =
    {
      snapshot =
        Observer.Snapshot.create ~value:(Observer.Value.current 1)
          ~delivery:
            (Observer.Delivery.Observer_delivery_pending
               (8, update_changed, []));
    }
  in
  let observer = { live = Some live } in
  let event =
    Observer.make_delivery_event ~access:(observer_event_access events)
      (observer_delivery_port events)
      (observer_event_port events
         ~run_callback:(fun _observer token _callback ->
           if token = 8 then Eta.Effect.fail `Delivery_failed
           else Eta.Effect.unit))
      ~observer ~token:8 update_changed
  in
  expect_delivery_failed "delivery event failure"
    (Observer.Delivery_event.run
       ~after_claim:(fun () ->
         Eta.Effect.sync (fun () -> record events "after_claim"))
       [ event ]);
  Alcotest.(check string) "released" "pending"
    (Observer.Delivery.label (Observer.Snapshot.delivery live.snapshot));
  Alcotest.(check (list string))
    "events"
    [
      "access";
      "active";
      "access";
      "set:running";
      "after_claim";
      "access";
      "construct:8";
      "access";
      "run:8:callback";
      "access";
      "set:pending";
    ]
    !events

let test_make_delivery_event_skips_stale_claim_before_construct () =
  let events = ref [] in
  let live =
    {
      snapshot =
        Observer.Snapshot.create ~value:(Observer.Value.current 1)
          ~delivery:
            (Observer.Delivery.Observer_delivery_pending
               (9, update_changed, []));
    }
  in
  let observer = { live = Some live } in
  let event =
    Observer.make_delivery_event ~access:(observer_event_access events)
      (observer_delivery_port events)
      (observer_event_port events) ~observer ~token:9 update_changed
  in
  expect_effect_ok "stale delivery event"
    (Observer.Delivery_event.run
       ~after_claim:(fun () ->
         Eta.Effect.sync (fun () ->
             record events "after_claim";
             live.snapshot <-
               Observer.Snapshot.with_delivery live.snapshot
                 (Observer.Delivery.Observer_delivered 2)))
       [ event ]);
  Alcotest.(check string) "stale delivered" "delivered"
    (Observer.Delivery.label (Observer.Snapshot.delivery live.snapshot));
  Alcotest.(check (list string))
    "events"
    [
      "access";
      "active";
      "access";
      "set:running";
      "after_claim";
      "access";
    ]
    !events

let test_snapshot_event_plan () =
  let initial = Observer.Snapshot.initial in
  let initialized =
    Observer.Snapshot.plan_event ~equal:Int.equal ~changed:true ~value:1
      initial
  in
  Observer.Snapshot.event_plan initialized
    ~plan:(fun ~snapshot ~update:planned_update ->
      Alcotest.(check (option update)) "initialized update"
        (Some update_initialized) planned_update;
      Alcotest.(check string) "initialized value" "current"
        (Observer.Value.label (Observer.Snapshot.value snapshot)));
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
  Observer.Snapshot.event_plan suppressed
    ~plan:(fun ~snapshot ~update:planned_update ->
      Alcotest.(check (option update)) "suppressed update" None planned_update;
      Alcotest.(check string) "suppressed delivery" "delivered"
        (Observer.Delivery.label (Observer.Snapshot.delivery snapshot)))

let check_snapshot_event_plan label ~delivery ~changed ~value
    ~expected_value ~expected_update ~expected_delivery_label =
  let snapshot =
    Observer.Snapshot.create ~value:Observer.Value.uninitialized ~delivery
  in
  Observer.Snapshot.plan_event ~equal:Int.equal ~changed ~value snapshot
  |> Observer.Snapshot.event_plan ~plan:(fun ~snapshot ~update:planned_update ->
         Alcotest.(check (option update)) (label ^ " update") expected_update
           planned_update;
         Alcotest.(check string)
           (label ^ " delivery") expected_delivery_label
           (Observer.Delivery.label (Observer.Snapshot.delivery snapshot));
         Alcotest.(check int)
           (label ^ " current value")
           expected_value
           (match Observer.Value.read (Observer.Snapshot.value snapshot) with
           | Ok value -> value
           | Error _ -> Alcotest.fail "expected current observer value"))

let test_event_plan_initializes_and_suppresses_unchanged () =
  let open Observer.Delivery in
  check_snapshot_event_plan "initial"
    ~delivery:Observer_never_delivered ~changed:false ~value:1
    ~expected_value:1 ~expected_delivery_label:"never_delivered"
    ~expected_update:(Some (Observer.Update.Initialized 1));
  check_snapshot_event_plan "unchanged"
    ~delivery:(Observer_delivered 1) ~changed:false ~value:1
    ~expected_value:1
    ~expected_update:None ~expected_delivery_label:"delivered"

let test_event_plan_changed_and_cutoff () =
  let open Observer.Delivery in
  check_snapshot_event_plan "changed"
    ~delivery:(Observer_delivered 1) ~changed:true ~value:2
    ~expected_value:2
    ~expected_update:
      (Some (Observer.Update.Changed { old_value = 1; new_value = 2 }))
    ~expected_delivery_label:"delivered";
  check_snapshot_event_plan "equal cutoff"
    ~delivery:(Observer_delivered 1) ~changed:true ~value:1
    ~expected_value:1
    ~expected_update:None ~expected_delivery_label:"delivered"

let test_event_plan_pending_delivery () =
  let open Observer.Delivery in
  check_snapshot_event_plan "pending changed"
    ~delivery:(Observer_delivery_pending (7, update_changed, []))
    ~changed:false ~value:2
    ~expected_value:2
    ~expected_update:
      (Some (Observer.Update.Changed { old_value = 1; new_value = 2 }))
    ~expected_delivery_label:"pending";
  check_snapshot_event_plan "pending reverted"
    ~delivery:(Observer_delivery_pending (7, update_changed, []))
    ~changed:false ~value:1
    ~expected_value:1
    ~expected_update:None ~expected_delivery_label:"delivered"

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
          Alcotest.test_case "diagnostic visibility" `Quick
            test_lifecycle_diagnostic_visibility;
          Alcotest.test_case "activate" `Quick test_lifecycle_activate;
          Alcotest.test_case "finish" `Quick test_lifecycle_finish;
          Alcotest.test_case "port activation and finish" `Quick
            test_lifecycle_port_owns_activation_finish_and_removal;
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
          Alcotest.test_case "generated traces match model" `Quick
            test_delivery_generated_traces_match_model;
          Alcotest.test_case "labels" `Quick test_delivery_labels;
          Alcotest.test_case "runner order" `Quick
            test_delivery_runner_orders_claimed_events;
          Alcotest.test_case "runner release on failure" `Quick
            test_delivery_runner_releases_claim_on_failure;
          Alcotest.test_case "runner delivered ack failure" `Quick
            test_delivery_runner_finishes_acknowledged_failure_as_delivered;
          Alcotest.test_case "event order" `Quick
            test_delivery_event_marks_and_runs_claimed_events;
          Alcotest.test_case "event finish error" `Quick
            test_delivery_event_finishes_error;
          Alcotest.test_case "handle accessors" `Quick
            test_delivery_handle_accessors;
          Alcotest.test_case "make handle token and acknowledge" `Quick
            test_make_delivery_handle_owns_token_and_acknowledge;
          Alcotest.test_case "port claim acknowledge finish" `Quick
            test_delivery_port_claim_acknowledge_and_finish;
          Alcotest.test_case "port ignores stale delivery" `Quick
            test_delivery_port_ignores_missing_or_stale_delivery;
          Alcotest.test_case "port marks failed without current" `Quick
            test_delivery_port_marks_failed_without_current;
          Alcotest.test_case "collect event stages snapshot" `Quick
            test_collect_event_stages_snapshot_and_constructs_event;
          Alcotest.test_case "collect event skips inactive" `Quick
            test_collect_event_skips_inactive_and_invalidated_observers;
          Alcotest.test_case "event collection marks pending" `Quick
            test_delivery_event_collection_marks_pending;
          Alcotest.test_case "make event success transitions" `Quick
            test_make_delivery_event_owns_success_transitions;
          Alcotest.test_case "make event releases claim on failure" `Quick
            test_make_delivery_event_releases_claim_on_failure;
          Alcotest.test_case "make event skips stale construct" `Quick
            test_make_delivery_event_skips_stale_claim_before_construct;
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
