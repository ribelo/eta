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

let () =
  Alcotest.run "eta_signal_bind"
    [
      ( "bind",
        [
          Alcotest.test_case "empty snapshot" `Quick test_empty_snapshot;
          Alcotest.test_case "switch snapshot" `Quick test_switch_snapshot;
        ] );
    ]
