module T = Eta_signal_transaction

type test_error = [ `Preflight_failed ]

let commit_ok tx =
  match T.commit tx with
  | Ok committed -> committed
  | Error `Preflight_failed -> Alcotest.fail "unexpected preflight failure"

let expect_invalid_arg label f =
  match f () with
  | exception Invalid_argument _ -> ()
  | exception exn ->
      Alcotest.failf "%s: expected Invalid_argument, got %s" label
        (Printexc.to_string exn)
  | _ -> Alcotest.failf "%s: expected Invalid_argument" label

let test_stage_read_commit () =
  let cell = T.create_staged 1 in
  let tx : (T.pure, test_error) T.t = T.begin_pure () in
  Alcotest.(check int) "initial current" 1 (T.current cell);
  Alcotest.(check int) "initial read" 1 (T.read tx cell);
  T.stage tx cell 2;
  Alcotest.(check bool) "cell is staged" true (T.staged tx cell);
  Alcotest.(check int) "staged read" 2 (T.read tx cell);
  Alcotest.(check int) "current unchanged before commit" 1 (T.current cell);
  let committed = commit_ok tx in
  Alcotest.(check int) "current committed" 2 (T.current cell);
  Alcotest.(check int) "committed read" 2 (T.read committed cell);
  Alcotest.(check bool) "staging cleared" false (T.staged committed cell)

let test_restage_uses_last_value () =
  let cell = T.create_staged 0 in
  let tx : (T.pure, test_error) T.t = T.begin_pure () in
  T.stage tx cell 1;
  T.stage tx cell 2;
  Alcotest.(check int) "staged last value" 2 (T.read tx cell);
  ignore (commit_ok tx : (T.committed, test_error) T.t);
  Alcotest.(check int) "committed last value" 2 (T.current cell)

let test_set_current_preserves_pending_transaction_value () =
  let cell = T.create_staged 0 in
  let tx : (T.pure, test_error) T.t = T.begin_pure () in
  T.stage tx cell 1;
  T.set_current cell 2;
  Alcotest.(check int) "transaction reads pending value" 1 (T.read tx cell);
  Alcotest.(check int) "outside read sees current value" 2 (T.current cell);
  T.rollback tx;
  Alcotest.(check int) "rollback keeps explicit current value" 2 (T.current cell)

let test_stage_read_rollback () =
  let cell = T.create_staged "old" in
  let tx : (T.pure, test_error) T.t = T.begin_pure () in
  T.stage tx cell "new";
  Alcotest.(check string) "staged read" "new" (T.read tx cell);
  T.rollback tx;
  Alcotest.(check string) "current restored" "old" (T.current cell);
  Alcotest.(check string) "read after rollback uses current" "old"
    (T.read tx cell);
  Alcotest.(check bool) "staging cleared" false (T.staged tx cell)

let test_two_transactions_cannot_share_pending_state () =
  let cell = T.create_staged 0 in
  let first : (T.pure, test_error) T.t = T.begin_pure () in
  let second : (T.pure, test_error) T.t = T.begin_pure () in
  T.stage first cell 1;
  Alcotest.(check bool) "first owns staged value" true (T.staged first cell);
  Alcotest.(check bool)
    "second does not own staged value" false (T.staged second cell);
  Alcotest.(check int) "second reads current" 0 (T.read second cell);
  expect_invalid_arg "stage through second transaction" (fun () ->
      T.stage second cell 2);
  T.rollback first;
  T.stage second cell 3;
  ignore (commit_ok second : (T.committed, test_error) T.t);
  Alcotest.(check int) "second commits after first rollback" 3 (T.current cell)

let test_commit_hooks_run_once () =
  let cell = T.create_staged 0 in
  let tx : (T.pure, test_error) T.t = T.begin_pure () in
  let commit_calls = ref 0 in
  let rollback_calls = ref 0 in
  T.stage tx cell 1;
  T.on_commit tx (fun () -> incr commit_calls);
  T.on_rollback tx (fun () -> incr rollback_calls);
  ignore (commit_ok tx : (T.committed, test_error) T.t);
  Alcotest.(check int) "commit hook ran once" 1 !commit_calls;
  Alcotest.(check int) "rollback hook did not run" 0 !rollback_calls;
  expect_invalid_arg "commit is closed" (fun () -> ignore (T.commit tx))

let test_rollback_hooks_run_once () =
  let cell = T.create_staged 0 in
  let tx : (T.pure, test_error) T.t = T.begin_pure () in
  let commit_calls = ref 0 in
  let rollback_calls = ref 0 in
  T.stage tx cell 1;
  T.on_commit tx (fun () -> incr commit_calls);
  T.on_rollback tx (fun () -> incr rollback_calls);
  T.rollback tx;
  Alcotest.(check int) "commit hook did not run" 0 !commit_calls;
  Alcotest.(check int) "rollback hook ran once" 1 !rollback_calls;
  expect_invalid_arg "rollback is closed" (fun () -> T.rollback tx)

let test_preflight_failure_leaves_current_values_unchanged () =
  let left = T.create_staged 1 in
  let right = T.create_staged 10 in
  let tx : (T.pure, test_error) T.t = T.begin_pure () in
  let commit_calls = ref 0 in
  let rollback_calls = ref 0 in
  T.stage tx left 2;
  T.stage tx right 20;
  T.on_preflight tx (fun () -> Error `Preflight_failed);
  T.on_commit tx (fun () -> incr commit_calls);
  T.on_rollback tx (fun () -> incr rollback_calls);
  (match T.commit tx with
   | Error `Preflight_failed -> ()
   | Ok _ -> Alcotest.fail "expected preflight failure");
  Alcotest.(check int) "left current unchanged" 1 (T.current left);
  Alcotest.(check int) "right current unchanged" 10 (T.current right);
  Alcotest.(check int) "left staged value still readable" 2 (T.read tx left);
  Alcotest.(check int) "right staged value still readable" 20 (T.read tx right);
  Alcotest.(check int) "commit hook did not run" 0 !commit_calls;
  Alcotest.(check int) "rollback hook did not run automatically" 0
    !rollback_calls;
  T.rollback tx;
  Alcotest.(check int) "rollback hook ran after explicit rollback" 1
    !rollback_calls;
  Alcotest.(check int) "left current still unchanged" 1 (T.current left);
  Alcotest.(check int) "right current still unchanged" 10 (T.current right)

let () =
  Alcotest.run "eta_signal_transaction"
    [
      ( "transaction",
        [
          Alcotest.test_case "stage read commit" `Quick test_stage_read_commit;
          Alcotest.test_case "restage uses last value" `Quick
            test_restage_uses_last_value;
          Alcotest.test_case
            "set_current preserves pending transaction value" `Quick
            test_set_current_preserves_pending_transaction_value;
          Alcotest.test_case "stage read rollback" `Quick
            test_stage_read_rollback;
          Alcotest.test_case "two transactions cannot share pending state"
            `Quick test_two_transactions_cannot_share_pending_state;
          Alcotest.test_case "commit hooks run once" `Quick
            test_commit_hooks_run_once;
          Alcotest.test_case "rollback hooks run once" `Quick
            test_rollback_hooks_run_once;
          Alcotest.test_case "preflight failure leaves current unchanged"
            `Quick test_preflight_failure_leaves_current_values_unchanged;
        ] );
    ]
