module Bind = Eta_signal_bind

let test_empty_snapshot () =
  let snapshot = Bind.empty in
  Alcotest.(check (option int)) "source value" None
    (Bind.source_value snapshot);
  Alcotest.(check (option string)) "inner" None (Bind.inner snapshot);
  Alcotest.(check (option int)) "scope" None (Bind.inner_scope snapshot);
  Alcotest.(check bool) "needs initial inner" true
    (Bind.needs_new_inner ~equal:Int.equal snapshot 1);
  Alcotest.(check bool) "no switch parts" true
    (Option.is_none (Bind.switch_parts snapshot))

let test_switch_snapshot () =
  let snapshot = Bind.switch ~source_value:1 ~inner:"inner" ~scope:2 in
  Alcotest.(check (option int)) "source value" (Some 1)
    (Bind.source_value snapshot);
  Alcotest.(check (option string)) "inner" (Some "inner")
    (Bind.inner snapshot);
  Alcotest.(check (option int)) "scope" (Some 2) (Bind.inner_scope snapshot);
  Alcotest.(check bool) "same source reuses inner" false
    (Bind.needs_new_inner ~equal:Int.equal snapshot 1);
  Alcotest.(check bool) "changed source needs inner" true
    (Bind.needs_new_inner ~equal:Int.equal snapshot 2);
  match Bind.switch_parts snapshot with
  | Some (source_value, inner, scope) ->
      Alcotest.(check int) "switch source" 1 source_value;
      Alcotest.(check string) "switch inner" "inner" inner;
      Alcotest.(check int) "switch scope" 2 scope
  | None -> Alcotest.fail "expected complete switch parts"

let test_switch_commit_plan () =
  let current = Bind.switch ~source_value:0 ~inner:"old" ~scope:1 in
  let staged = Bind.switch ~source_value:1 ~inner:"new" ~scope:2 in
  match Bind.commit_switch ~current ~staged with
  | Ok plan ->
      Alcotest.(check (option string)) "old inner" (Some "old") plan.old_inner;
      Alcotest.(check (option int)) "old scope" (Some 1) plan.old_scope;
      Alcotest.(check string) "new inner" "new" plan.new_inner
  | Error `Invalid_scope -> Alcotest.fail "expected commit plan"

let test_switch_rollback_and_preflight_plans () =
  let current = Bind.switch ~source_value:0 ~inner:"old" ~scope:1 in
  let staged = Bind.switch ~source_value:1 ~inner:"new" ~scope:2 in
  (match Bind.rollback_switch ~staged with
   | Ok scope -> Alcotest.(check int) "rollback scope" 2 scope
   | Error `Invalid_scope -> Alcotest.fail "expected rollback scope");
  match Bind.preflight_switch ~current ~staged with
  | Ok old_scope ->
      Alcotest.(check (option int)) "preflight old scope" (Some 1) old_scope
  | Error `Invalid_scope -> Alcotest.fail "expected preflight scope"

let test_switch_plans_reject_incomplete_staged_snapshot () =
  let current = Bind.switch ~source_value:0 ~inner:"old" ~scope:1 in
  Alcotest.(check bool) "commit rejected" true
    (Result.is_error (Bind.commit_switch ~current ~staged:Bind.empty));
  Alcotest.(check bool) "rollback rejected" true
    (Result.is_error (Bind.rollback_switch ~staged:Bind.empty));
  Alcotest.(check bool) "preflight rejected" true
    (Result.is_error (Bind.preflight_switch ~current ~staged:Bind.empty))

let () =
  Alcotest.run "eta_signal_bind"
    [
      ( "bind",
        [
          Alcotest.test_case "empty snapshot" `Quick test_empty_snapshot;
          Alcotest.test_case "switch snapshot" `Quick test_switch_snapshot;
          Alcotest.test_case "switch commit plan" `Quick
            test_switch_commit_plan;
          Alcotest.test_case "switch rollback and preflight plans" `Quick
            test_switch_rollback_and_preflight_plans;
          Alcotest.test_case "incomplete switch rejected" `Quick
            test_switch_plans_reject_incomplete_staged_snapshot;
        ] );
    ]
