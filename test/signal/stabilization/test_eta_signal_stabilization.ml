module S = Eta_signal_stabilization
module T = Eta_signal_transaction

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
  ignore (S.finish_delivering state delivering : S.idle S.token);
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
  ignore (S.collect_to_delivering state committed : S.delivering S.token);
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
  ignore (S.commit_to_delivering state pure : S.delivering S.token);
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
  ignore (S.finish_delivering state delivering : S.idle S.token);
  Alcotest.(check bool) "finished idle" true
    (match S.state state with
    | Idle -> true
    | Pure | Committed | Delivering -> false);
  expect_invalid_arg "reused delivering token" (fun () ->
      ignore (S.finish_delivering state delivering : S.idle S.token))

let test_rollback_invalidates_pure_token () =
  let state = S.create () in
  let pure =
    match S.begin_pure state with
    | Ok pure -> pure
    | Error `Reentrant_stabilization ->
        Alcotest.fail "expected begin to succeed"
  in
  S.rollback_transaction state;
  ignore (S.rollback_to_idle state pure : S.idle S.token);
  Alcotest.(check bool) "rolled back idle" true
    (match S.state state with
    | Idle -> true
    | Pure | Committed | Delivering -> false);
  expect_invalid_arg "reused pure token" (fun () ->
      ignore (S.commit_to_committed state pure : S.committed S.token))

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
      ignore (S.commit_to_committed second first_pure : S.committed S.token));
  let second_committed = S.commit_to_committed second second_pure in
  (match S.commit_transaction first with
   | Ok () -> ()
   | Error () -> Alcotest.fail "first commit unexpectedly failed");
  let first_committed = S.commit_to_committed first first_pure in
  expect_invalid_arg "foreign committed token" (fun () ->
      ignore
        (S.collect_to_delivering second first_committed
          : S.delivering S.token));
  let second_delivering = S.collect_to_delivering second second_committed in
  let first_delivering = S.collect_to_delivering first first_committed in
  ignore (S.finish_delivering first first_delivering : S.idle S.token);
  ignore (S.finish_delivering second second_delivering : S.idle S.token)

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
  ignore (S.commit_to_committed state pure : S.committed S.token)

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
  ignore (S.rollback_to_idle state pure : S.idle S.token)

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
        ] );
    ]
