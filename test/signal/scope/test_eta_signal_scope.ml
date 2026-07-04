module Scope = Eta_signal_scope

let test_create_and_accessors () =
  let root = Scope.create ~id:1 ~owner:"root-owner" ~parent:None in
  let child = Scope.create ~id:2 ~owner:"child-owner" ~parent:(Some root) in
  Alcotest.(check int) "root id" 1 (Scope.id root);
  Alcotest.(check string) "child owner" "child-owner" (Scope.owner child);
  Alcotest.(check bool) "child valid" true (Scope.valid child);
  Alcotest.(check int) "child parent" 1
    (match Scope.parent child with
    | Some parent -> Scope.id parent
    | None -> Alcotest.fail "expected parent")

let test_add_and_invalidate_nodes () =
  let scope = Scope.create ~id:1 ~owner:"owner" ~parent:None in
  Scope.add_node scope "first";
  Scope.add_node scope "second";
  Alcotest.(check (list string)) "nodes are consed" [ "second"; "first" ]
    (Scope.nodes scope);
  (match Scope.invalidate scope with
  | Some nodes ->
      Alcotest.(check (list string)) "invalidated nodes" [ "second"; "first" ]
        nodes
  | None -> Alcotest.fail "expected first invalidation");
  Alcotest.(check bool) "invalid" false (Scope.valid scope);
  Alcotest.(check (list string)) "nodes cleared" [] (Scope.nodes scope);
  (match Scope.invalidate scope with
  | Some _ -> Alcotest.fail "expected second invalidation to be ignored"
  | None -> ())

let test_ancestor_and_depth () =
  let root = Scope.create ~id:1 ~owner:"root" ~parent:None in
  let child = Scope.create ~id:2 ~owner:"child" ~parent:(Some root) in
  let grandchild = Scope.create ~id:3 ~owner:"grandchild" ~parent:(Some child) in
  Alcotest.(check bool) "root ancestor" true
    (Scope.is_ancestor ~ancestor:root grandchild);
  Alcotest.(check bool) "self ancestor" true
    (Scope.is_ancestor ~ancestor:child child);
  Alcotest.(check bool) "child not ancestor of root" false
    (Scope.is_ancestor ~ancestor:child root);
  Alcotest.(check int) "none depth" 0 (Scope.depth None);
  Alcotest.(check int) "grandchild depth" 3 (Scope.depth (Some grandchild))

let () =
  Alcotest.run "eta_signal_scope"
    [
      ( "scope",
        [
          Alcotest.test_case "create and accessors" `Quick
            test_create_and_accessors;
          Alcotest.test_case "add and invalidate nodes" `Quick
            test_add_and_invalidate_nodes;
          Alcotest.test_case "ancestor and depth" `Quick
            test_ancestor_and_depth;
        ] );
    ]
