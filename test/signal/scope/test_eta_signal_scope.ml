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

type node = {
  node_id : int;
  mutable node_valid : bool;
  mutable node_scope : (int, string, node) Scope.t option;
  mutable node_children : node list;
}

module Validation = Scope.Make_validation (struct
  type node_id = int
  type scope_id = int
  type owner = string
  type nonrec node = node

  let node_id node = node.node_id
  let valid node = node.node_valid
  let scope node = node.node_scope
  let children node = node.node_children
end)

let node ?(valid = true) ?scope ?(children = []) id =
  { node_id = id; node_valid = valid; node_scope = scope; node_children = children }

let check_valid name scope node =
  match Validation.validate_inner ~scope node with
  | Ok () -> ()
  | Error `Invalid_scope -> Alcotest.fail (name ^ ": expected valid")

let check_invalid name scope node =
  match Validation.validate_inner ~scope node with
  | Ok () -> Alcotest.fail (name ^ ": expected invalid")
  | Error `Invalid_scope -> ()

let test_validate_inner_accepts_unscoped_and_ancestor_scoped_nodes () =
  let root = Scope.create ~id:1 ~owner:"root" ~parent:None in
  let child = Scope.create ~id:2 ~owner:"child" ~parent:(Some root) in
  check_valid "unscoped" child (node 1);
  check_valid "ancestor scoped" child (node ~scope:root 2);
  check_valid "same scoped" child (node ~scope:child 3)

let test_validate_inner_rejects_invalid_nodes_and_scopes () =
  let root = Scope.create ~id:1 ~owner:"root" ~parent:None in
  let child = Scope.create ~id:2 ~owner:"child" ~parent:(Some root) in
  let unrelated = Scope.create ~id:3 ~owner:"other" ~parent:None in
  check_invalid "invalid node" child (node ~valid:false 1);
  check_invalid "unrelated scope" child (node ~scope:unrelated 2);
  ignore (Scope.invalidate root : node list option);
  check_invalid "invalid ancestor scope" child (node ~scope:root 3)

let test_validate_inner_traverses_children_and_deduplicates () =
  let root = Scope.create ~id:1 ~owner:"root" ~parent:None in
  let invalid = node ~valid:false 2 in
  let child = node 1 in
  child.node_children <- [ invalid; invalid ];
  check_invalid "invalid child" root child;
  child.node_children <- [ child ];
  check_valid "cycle deduplicated" root child

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
          Alcotest.test_case "validate accepts scoped nodes" `Quick
            test_validate_inner_accepts_unscoped_and_ancestor_scoped_nodes;
          Alcotest.test_case "validate rejects invalid nodes" `Quick
            test_validate_inner_rejects_invalid_nodes_and_scopes;
          Alcotest.test_case "validate traverses children" `Quick
            test_validate_inner_traverses_children_and_deduplicates;
        ] );
    ]
