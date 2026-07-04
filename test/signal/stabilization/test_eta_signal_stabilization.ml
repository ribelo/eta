module S = Eta_signal_stabilization
module T = Eta_signal_transaction

type owner
type 'state token = (owner, 'state) S.token
type 'error stabilization = (owner, 'error) S.t

let expect_invalid_arg label f =
  match f () with
  | exception Invalid_argument _ -> ()
  | exception exn ->
      Alcotest.failf "%s: expected Invalid_argument, got %s" label
        (Printexc.to_string exn)
  | _ -> Alcotest.failf "%s: expected Invalid_argument" label

let test_begin_commit_finish () =
  let state = S.create () in
  Alcotest.(check bool) "starts idle" true
    (match S.state state with
    | Idle -> true
    | Pure | Committed | Delivering -> false);
  let pure =
    match S.begin_pure state with
    | Ok pure -> pure
    | Error `Reentrant_stabilization ->
        Alcotest.fail "expected idle begin to succeed"
  in
  Alcotest.(check bool) "pure" true (S.is_pure state);
  (match S.commit_transaction state with
   | Ok () -> ()
   | Error () -> Alcotest.fail "commit unexpectedly failed");
  let committed =
    S.commit_to_committed state pure
  in
  Alcotest.(check bool) "committed" true
    (match S.state state with
    | Committed -> true
    | Idle | Pure | Delivering -> false);
  let delivering = S.collect_to_delivering state committed in
  Alcotest.(check bool) "delivering" true
    (match S.state state with
    | Delivering -> true
    | Idle | Pure | Committed -> false);
  ignore (S.finish_delivering state delivering : S.idle token);
  Alcotest.(check bool) "finished idle" true
    (match S.state state with
    | Idle -> true
    | Pure | Committed | Delivering -> false)

let test_reentrant_begin_rejected () =
  let state = S.create () in
  let pure =
    match S.begin_pure state with
    | Ok pure -> pure
    | Error `Reentrant_stabilization ->
        Alcotest.fail "expected first begin to succeed"
  in
  (match S.begin_pure state with
   | Error `Reentrant_stabilization -> ()
   | Ok _ -> Alcotest.fail "expected reentrant pure begin to fail");
  (match S.commit_transaction state with
   | Ok () -> ()
   | Error () -> Alcotest.fail "commit unexpectedly failed");
  let committed = S.commit_to_committed state pure in
  (match S.begin_pure state with
   | Error `Reentrant_stabilization -> ()
   | Ok _ -> Alcotest.fail "expected committed begin to fail");
  ignore (S.collect_to_delivering state committed : S.delivering token);
  (match S.begin_pure state with
   | Error `Reentrant_stabilization -> ()
   | Ok _ -> Alcotest.fail "expected delivering begin to fail")

let test_commit_to_delivering_combines_transitions () =
  let state = S.create () in
  let pure =
    match S.begin_pure state with
    | Ok pure -> pure
    | Error `Reentrant_stabilization ->
        Alcotest.fail "expected begin to succeed"
  in
  (match S.commit_transaction state with
   | Ok () -> ()
   | Error () -> Alcotest.fail "commit unexpectedly failed");
  ignore (S.commit_to_delivering state pure : S.delivering token);
  Alcotest.(check bool) "delivering" true
    (match S.state state with
    | Delivering -> true
    | Idle | Pure | Committed -> false)

let test_finish_delivering_uses_token () =
  let state = S.create () in
  let pure =
    match S.begin_pure state with
    | Ok pure -> pure
    | Error `Reentrant_stabilization ->
        Alcotest.fail "expected begin to succeed"
  in
  (match S.commit_transaction state with
   | Ok () -> ()
   | Error () -> Alcotest.fail "commit unexpectedly failed");
  let delivering = S.commit_to_delivering state pure in
  ignore (S.finish_delivering state delivering : S.idle token);
  Alcotest.(check bool) "finished idle" true
    (match S.state state with
    | Idle -> true
    | Pure | Committed | Delivering -> false);
  expect_invalid_arg "reused delivering token" (fun () ->
      ignore (S.finish_delivering state delivering : S.idle token))

let test_rollback_invalidates_pure_token () =
  let state = S.create () in
  let pure =
    match S.begin_pure state with
    | Ok pure -> pure
    | Error `Reentrant_stabilization ->
        Alcotest.fail "expected begin to succeed"
  in
  S.rollback_transaction state;
  ignore (S.rollback_to_idle state pure : S.idle token);
  Alcotest.(check bool) "rolled back idle" true
    (match S.state state with
    | Idle -> true
    | Pure | Committed | Delivering -> false);
  expect_invalid_arg "reused pure token" (fun () ->
      ignore (S.commit_to_committed state pure : S.committed token))

let test_tokens_are_bound_to_state () =
  let first = S.create () in
  let second = S.create () in
  let first_pure =
    match S.begin_pure first with
    | Ok pure -> pure
    | Error `Reentrant_stabilization ->
        Alcotest.fail "expected first begin to succeed"
  in
  let second_pure =
    match S.begin_pure second with
    | Ok pure -> pure
    | Error `Reentrant_stabilization ->
        Alcotest.fail "expected second begin to succeed"
  in
  (match S.commit_transaction second with
   | Ok () -> ()
   | Error () -> Alcotest.fail "second commit unexpectedly failed");
  expect_invalid_arg "foreign pure token" (fun () ->
      ignore (S.commit_to_committed second first_pure : S.committed token));
  let second_committed = S.commit_to_committed second second_pure in
  (match S.commit_transaction first with
   | Ok () -> ()
   | Error () -> Alcotest.fail "first commit unexpectedly failed");
  let first_committed = S.commit_to_committed first first_pure in
  expect_invalid_arg "foreign committed token" (fun () ->
      ignore
        (S.collect_to_delivering second first_committed
          : S.delivering token));
  let second_delivering = S.collect_to_delivering second second_committed in
  let first_delivering = S.collect_to_delivering first first_committed in
  ignore (S.finish_delivering first first_delivering : S.idle token);
  ignore (S.finish_delivering second second_delivering : S.idle token)

let test_begin_opens_transaction () =
  let state = S.create () in
  let staged = T.create_staged 1 in
  let pure =
    match S.begin_pure state with
    | Ok pure -> pure
    | Error `Reentrant_stabilization ->
        Alcotest.fail "expected begin to succeed"
  in
  let transaction = S.active_transaction state in
  T.stage transaction staged 2;
  Alcotest.(check int) "staged read" 2 (T.read transaction staged);
  Alcotest.(check int) "current unchanged" 1 (T.current staged);
  (match S.commit_transaction state with
   | Ok () -> ()
   | Error () -> Alcotest.fail "commit unexpectedly failed");
  Alcotest.(check int) "current committed" 2 (T.current staged);
  expect_invalid_arg "active transaction after commit" (fun () ->
      ignore (S.active_transaction state : (T.pure, unit) T.t));
  ignore (S.commit_to_committed state pure : S.committed token)

let test_rollback_transaction_clears_staged_value () =
  let state = S.create () in
  let staged = T.create_staged "current" in
  let pure =
    match S.begin_pure state with
    | Ok pure -> pure
    | Error `Reentrant_stabilization ->
        Alcotest.fail "expected begin to succeed"
  in
  let transaction = S.active_transaction state in
  T.stage transaction staged "staged";
  S.rollback_transaction state;
  Alcotest.(check string) "current preserved" "current" (T.current staged);
  expect_invalid_arg "active transaction after rollback" (fun () ->
      ignore (S.active_transaction state : (T.pure, unit) T.t));
  ignore (S.rollback_to_idle state pure : S.idle token)

let begin_or_fail state =
  match S.begin_pure state with
  | Ok pure -> pure
  | Error `Reentrant_stabilization ->
      Alcotest.fail "expected begin to succeed"

let commit_transaction_or_fail state =
  match S.commit_transaction state with
  | Ok () -> ()
  | Error () -> Alcotest.fail "commit unexpectedly failed"

let test_commit_after_transaction_rollback_rejected () =
  let state = S.create () in
  let pure = begin_or_fail state in
  S.rollback_transaction state;
  expect_invalid_arg "commit after transaction rollback" (fun () ->
      ignore (S.commit_to_committed state pure : S.committed token));
  ignore (S.rollback_to_idle state pure : S.idle token)

let test_rollback_after_transaction_commit_rejected () =
  let state = S.create () in
  let pure = begin_or_fail state in
  commit_transaction_or_fail state;
  expect_invalid_arg "rollback after transaction commit" (fun () ->
      ignore (S.rollback_to_idle state pure : S.idle token));
  let delivering = S.commit_to_delivering state pure in
  ignore (S.finish_delivering state delivering : S.idle token)

type model_phase =
  | Model_idle
  | Model_pure
  | Model_committed
  | Model_delivering

type model = {
  mutable model_phase : model_phase;
  mutable model_tx_active : bool;
  mutable model_tx_committed : bool;
  mutable model_tx_rolled_back : bool;
}

type machine = {
  state : unit stabilization;
  mutable pure_token : S.pure token option;
  mutable committed_token : S.committed token option;
  mutable delivering_token : S.delivering token option;
}

type op =
  | Begin
  | Commit_transaction
  | Rollback_transaction
  | Commit_to_committed
  | Collect_to_delivering
  | Commit_to_delivering
  | Rollback_to_idle
  | Finish_delivering

let ops =
  [
    Begin;
    Commit_transaction;
    Rollback_transaction;
    Commit_to_committed;
    Collect_to_delivering;
    Commit_to_delivering;
    Rollback_to_idle;
    Finish_delivering;
  ]

let op_label = function
  | Begin -> "begin"
  | Commit_transaction -> "commit_tx"
  | Rollback_transaction -> "rollback_tx"
  | Commit_to_committed -> "commit_to_committed"
  | Collect_to_delivering -> "collect_to_delivering"
  | Commit_to_delivering -> "commit_to_delivering"
  | Rollback_to_idle -> "rollback_to_idle"
  | Finish_delivering -> "finish_delivering"

let pp_model_phase fmt = function
  | Model_idle -> Format.pp_print_string fmt "idle"
  | Model_pure -> Format.pp_print_string fmt "pure"
  | Model_committed -> Format.pp_print_string fmt "committed"
  | Model_delivering -> Format.pp_print_string fmt "delivering"

let equal_model_phase left right =
  match (left, right) with
  | Model_idle, Model_idle | Model_pure, Model_pure
  | Model_committed, Model_committed | Model_delivering, Model_delivering ->
      true
  | _ -> false

let model_phase_testable =
  Alcotest.testable pp_model_phase equal_model_phase

let model_phase_of_state = function
  | S.Idle -> Model_idle
  | S.Pure -> Model_pure
  | S.Committed -> Model_committed
  | S.Delivering -> Model_delivering

let new_model () =
  {
    model_phase = Model_idle;
    model_tx_active = false;
    model_tx_committed = false;
    model_tx_rolled_back = false;
  }

let new_machine () =
  {
    state = S.create ();
    pure_token = None;
    committed_token = None;
    delivering_token = None;
  }

let clear_pure_transaction_model model =
  model.model_tx_active <- false;
  model.model_tx_committed <- false;
  model.model_tx_rolled_back <- false

let check_machine label machine model =
  Alcotest.(check model_phase_testable)
    (label ^ ": phase") model.model_phase
    (model_phase_of_state (S.state machine.state));
  Alcotest.(check bool)
    (label ^ ": is_pure")
    (equal_model_phase model.model_phase Model_pure)
    (S.is_pure machine.state);
  Alcotest.(check bool)
    (label ^ ": transaction option")
    model.model_tx_active
    (Option.is_some (S.transaction machine.state));
  if model.model_tx_active then
    ignore (S.active_transaction machine.state : (T.pure, unit) T.t)
  else
    expect_invalid_arg (label ^ ": no active transaction") (fun () ->
        ignore (S.active_transaction machine.state : (T.pure, unit) T.t))

let expect_invalid_token_op label token f =
  match token with
  | None -> ()
  | Some token -> expect_invalid_arg label (fun () -> ignore (f token))

let run_trace_op label machine model op =
  (match op with
   | Begin -> (
       match model.model_phase with
       | Model_idle -> (
           match S.begin_pure machine.state with
           | Ok pure ->
               machine.pure_token <- Some pure;
               machine.committed_token <- None;
               machine.delivering_token <- None;
               model.model_phase <- Model_pure;
               model.model_tx_active <- true;
               model.model_tx_committed <- false;
               model.model_tx_rolled_back <- false
           | Error `Reentrant_stabilization ->
               Alcotest.failf "%s: begin should succeed" label)
       | Model_pure | Model_committed | Model_delivering -> (
           match S.begin_pure machine.state with
           | Error `Reentrant_stabilization -> ()
           | Ok _ -> Alcotest.failf "%s: begin should be reentrant" label))
   | Commit_transaction ->
       if
         equal_model_phase model.model_phase Model_pure
         && model.model_tx_active
       then (
         commit_transaction_or_fail machine.state;
         model.model_tx_active <- false;
         model.model_tx_committed <- true;
         model.model_tx_rolled_back <- false)
       else
         expect_invalid_arg (label ^ ": commit transaction") (fun () ->
             commit_transaction_or_fail machine.state)
   | Rollback_transaction ->
       if
         equal_model_phase model.model_phase Model_pure
         && model.model_tx_active
       then (
         S.rollback_transaction machine.state;
         model.model_tx_active <- false;
         model.model_tx_committed <- false;
         model.model_tx_rolled_back <- true)
       else
         expect_invalid_arg (label ^ ": rollback transaction") (fun () ->
             S.rollback_transaction machine.state)
   | Commit_to_committed ->
       if
         equal_model_phase model.model_phase Model_pure
         && model.model_tx_committed
       then (
         match machine.pure_token with
         | None -> Alcotest.failf "%s: missing pure token" label
         | Some pure ->
             machine.committed_token <-
               Some (S.commit_to_committed machine.state pure);
             model.model_phase <- Model_committed;
             clear_pure_transaction_model model)
       else
         expect_invalid_token_op (label ^ ": commit to committed")
           machine.pure_token
           (fun pure -> S.commit_to_committed machine.state pure)
   | Collect_to_delivering ->
       if equal_model_phase model.model_phase Model_committed then (
         match machine.committed_token with
         | None -> Alcotest.failf "%s: missing committed token" label
         | Some committed ->
             machine.delivering_token <-
               Some (S.collect_to_delivering machine.state committed);
             model.model_phase <- Model_delivering)
       else
         expect_invalid_token_op (label ^ ": collect to delivering")
           machine.committed_token
           (fun committed -> S.collect_to_delivering machine.state committed)
   | Commit_to_delivering ->
       if
         equal_model_phase model.model_phase Model_pure
         && model.model_tx_committed
       then (
         match machine.pure_token with
         | None -> Alcotest.failf "%s: missing pure token" label
         | Some pure ->
             machine.delivering_token <-
               Some (S.commit_to_delivering machine.state pure);
             machine.committed_token <- None;
             model.model_phase <- Model_delivering;
             clear_pure_transaction_model model)
       else
         expect_invalid_token_op (label ^ ": commit to delivering")
           machine.pure_token
           (fun pure -> S.commit_to_delivering machine.state pure)
   | Rollback_to_idle ->
       if
         equal_model_phase model.model_phase Model_pure
         && model.model_tx_rolled_back
       then (
         match machine.pure_token with
         | None -> Alcotest.failf "%s: missing pure token" label
         | Some pure ->
             ignore (S.rollback_to_idle machine.state pure : S.idle token);
             model.model_phase <- Model_idle;
             clear_pure_transaction_model model)
       else
         expect_invalid_token_op (label ^ ": rollback to idle")
           machine.pure_token
           (fun pure -> S.rollback_to_idle machine.state pure)
   | Finish_delivering ->
       if equal_model_phase model.model_phase Model_delivering then (
         match machine.delivering_token with
         | None -> Alcotest.failf "%s: missing delivering token" label
         | Some delivering ->
             ignore
               (S.finish_delivering machine.state delivering : S.idle token);
             model.model_phase <- Model_idle)
       else
         expect_invalid_token_op (label ^ ": finish delivering")
           machine.delivering_token
           (fun delivering -> S.finish_delivering machine.state delivering));
  check_machine label machine model

let cleanup_trace_state label machine model =
  (match model.model_phase with
   | Model_idle -> ()
   | Model_pure when model.model_tx_active ->
       S.rollback_transaction machine.state;
       model.model_tx_active <- false;
       model.model_tx_rolled_back <- true;
       run_trace_op (label ^ ":cleanup:rollback_to_idle") machine model
         Rollback_to_idle
   | Model_pure when model.model_tx_rolled_back ->
       run_trace_op (label ^ ":cleanup:rollback_to_idle") machine model
         Rollback_to_idle
   | Model_pure when model.model_tx_committed ->
       run_trace_op (label ^ ":cleanup:commit_to_delivering") machine model
         Commit_to_delivering;
       run_trace_op (label ^ ":cleanup:finish_delivering") machine model
         Finish_delivering
   | Model_pure -> Alcotest.failf "%s: pure state has no transaction status" label
   | Model_committed ->
       run_trace_op (label ^ ":cleanup:collect_to_delivering") machine model
         Collect_to_delivering;
       run_trace_op (label ^ ":cleanup:finish_delivering") machine model
         Finish_delivering
   | Model_delivering ->
       run_trace_op (label ^ ":cleanup:finish_delivering") machine model
         Finish_delivering);
  Alcotest.(check model_phase_testable)
    (label ^ ": cleanup idle") Model_idle model.model_phase;
  check_machine (label ^ ": cleanup") machine model

let run_trace trace =
  let label =
    match trace with
    | [] -> "empty"
    | _ -> String.concat "," (List.map op_label trace)
  in
  let machine = new_machine () in
  let model = new_model () in
  check_machine (label ^ ":initial") machine model;
  List.iteri
    (fun index op ->
      run_trace_op
        (label ^ ":op" ^ string_of_int index ^ ":" ^ op_label op)
        machine model op)
    trace;
  cleanup_trace_state label machine model

let rec iter_traces length prefix f =
  if length = 0 then f (List.rev prefix)
  else
    List.iter
      (fun op -> iter_traces (length - 1) (op :: prefix) f)
      ops

let test_generated_transition_traces () =
  for length = 0 to 5 do
    iter_traces length [] run_trace
  done

let () =
  Alcotest.run "eta_signal_stabilization"
    [
      ( "stabilization",
        [
          Alcotest.test_case "begin commit finish" `Quick
            test_begin_commit_finish;
          Alcotest.test_case "reentrant begin rejected" `Quick
            test_reentrant_begin_rejected;
          Alcotest.test_case "commit to delivering" `Quick
            test_commit_to_delivering_combines_transitions;
          Alcotest.test_case "finish delivering" `Quick
            test_finish_delivering_uses_token;
          Alcotest.test_case "rollback invalidates pure token" `Quick
            test_rollback_invalidates_pure_token;
          Alcotest.test_case "tokens are bound to state" `Quick
            test_tokens_are_bound_to_state;
          Alcotest.test_case "begin opens transaction" `Quick
            test_begin_opens_transaction;
          Alcotest.test_case "rollback transaction clears staged value" `Quick
            test_rollback_transaction_clears_staged_value;
          Alcotest.test_case "commit after rollback rejected" `Quick
            test_commit_after_transaction_rollback_rejected;
          Alcotest.test_case "rollback after commit rejected" `Quick
            test_rollback_after_transaction_commit_rejected;
          Alcotest.test_case "generated transition traces" `Quick
            test_generated_transition_traces;
        ] );
    ]
