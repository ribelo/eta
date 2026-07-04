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

let test_children_with_scope_owner () =
  let valid_owner = (1, true) in
  let invalid_owner = (2, false) in
  let owner_valid (_id, valid) = valid in
  let owner_node (id, _valid) = "owner-" ^ string_of_int id in
  let children = [ "child" ] in
  Alcotest.(check (list string))
    "root children unchanged"
    children
    (Scope.children_with_scope_owner ~owner_valid ~owner_node None children);
  let scope = Scope.create ~id:1 ~owner:valid_owner ~parent:None in
  Alcotest.(check (list string))
    "valid owner included"
    [ "owner-1"; "child" ]
    (Scope.children_with_scope_owner ~owner_valid ~owner_node (Some scope)
       children);
  let invalid_scope = Scope.create ~id:2 ~owner:valid_owner ~parent:None in
  ignore (Scope.invalidate invalid_scope : string list option);
  Alcotest.(check (list string))
    "invalid scope skipped"
    children
    (Scope.children_with_scope_owner ~owner_valid ~owner_node
       (Some invalid_scope) children);
  let invalid_owner_scope =
    Scope.create ~id:3 ~owner:invalid_owner ~parent:None
  in
  Alcotest.(check (list string))
    "invalid owner skipped"
    children
    (Scope.children_with_scope_owner ~owner_valid ~owner_node
       (Some invalid_owner_scope) children)

let current_id context = Option.map Scope.id (Scope.current context)

let test_context_tracks_and_restores_current_scope () =
  let context = Scope.create_context () in
  let root = Scope.create ~id:1 ~owner:"root" ~parent:None in
  let child = Scope.create ~id:2 ~owner:"child" ~parent:(Some root) in
  Alcotest.(check (option int)) "initial current" None (current_id context);
  let result =
    Scope.with_current context root (fun () ->
        Alcotest.(check (option int)) "root current" (Some 1)
          (current_id context);
        Scope.with_current context child (fun () ->
            Alcotest.(check (option int)) "child current" (Some 2)
              (current_id context);
            42))
  in
  Alcotest.(check int) "result" 42 result;
  Alcotest.(check (option int)) "restored empty current" None
    (current_id context)

let test_context_restores_current_scope_after_exception () =
  let context = Scope.create_context () in
  let root = Scope.create ~id:1 ~owner:"root" ~parent:None in
  let child = Scope.create ~id:2 ~owner:"child" ~parent:(Some root) in
  Scope.with_current context root (fun () ->
      (try
         Scope.with_current context child (fun () -> raise Exit)
       with Exit -> ());
      Alcotest.(check (option int)) "restored root current" (Some 1)
        (current_id context));
  Alcotest.(check (option int)) "restored empty current" None
    (current_id context)

let test_require_valid_current_scope () =
  let context = Scope.create_context () in
  let root = Scope.create ~id:1 ~owner:"root" ~parent:None in
  (match Scope.require_valid_current context with
  | Ok _ -> Alcotest.fail "expected ambiguous scope without current"
  | Error `Ambiguous_scope -> ());
  Scope.with_current context root (fun () ->
      (match Scope.require_valid_current context with
      | Ok scope -> Alcotest.(check int) "current scope" 1 (Scope.id scope)
      | Error `Ambiguous_scope -> Alcotest.fail "expected valid current");
      ignore (Scope.invalidate root : string list option);
      match Scope.require_valid_current context with
      | Ok _ -> Alcotest.fail "expected invalid current rejection"
      | Error `Ambiguous_scope -> ())

type node = {
  node_id : int;
  mutable node_valid : bool;
  mutable node_scope : (int, string, node) Scope.t option;
  mutable node_children : node list;
  mutable node_dependents : node list;
  mutable node_nested_scope : (int, string, node) Scope.t option;
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

let node ?(valid = true) ?scope ?(children = []) ?(dependents = [])
    ?nested_scope id =
  {
    node_id = id;
    node_valid = valid;
    node_scope = scope;
    node_children = children;
    node_dependents = dependents;
    node_nested_scope = nested_scope;
  }

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

module Invalidation = Scope.Make_invalidation (struct
  type node_id = int
  type scope_id = int
  type owner = string
  type nonrec node = node

  let node_id node = node.node_id
  let equal_node_id = Int.equal
  let valid node = node.node_valid
  let dependents node = node.node_dependents
  let nested_scope node = node.node_nested_scope
end)

let collected_ids ?exclude scope =
  let seen = Hashtbl.create 8 in
  let collected = ref [] in
  Invalidation.collect ?exclude_node_id:exclude seen collected scope;
  List.map (fun node -> node.node_id) !collected |> List.sort Int.compare

let test_invalidation_collects_dependents_and_nested_scope_nodes () =
  let root = Scope.create ~id:1 ~owner:"root" ~parent:None in
  let nested = Scope.create ~id:2 ~owner:"nested" ~parent:(Some root) in
  let dependent = node 2 in
  let source = node ~dependents:[ dependent ] 1 in
  let inner = node 4 in
  let dynamic = node ~nested_scope:nested 3 in
  Scope.add_node nested inner;
  Scope.add_node root source;
  Scope.add_node root dynamic;
  Alcotest.(check (list int))
    "collected ids" [ 1; 2; 3; 4 ] (collected_ids root)

let test_invalidation_excludes_node_and_skips_invalid_nested_scope () =
  let root = Scope.create ~id:1 ~owner:"root" ~parent:None in
  let nested = Scope.create ~id:2 ~owner:"nested" ~parent:(Some root) in
  let dependent = node 2 in
  let source = node ~dependents:[ dependent ] 1 in
  let inner = node 4 in
  let dynamic = node ~nested_scope:nested 3 in
  Scope.add_node nested inner;
  ignore (Scope.invalidate nested : node list option);
  Scope.add_node root source;
  Scope.add_node root dynamic;
  Alcotest.(check (list int))
    "excluded source and invalid nested scope"
    [ 3 ] (collected_ids ~exclude:1 root)

let test_invalidation_deduplicates_reachable_nodes () =
  let root = Scope.create ~id:1 ~owner:"root" ~parent:None in
  let shared = node 2 in
  let source = node ~dependents:[ shared; shared ] 1 in
  Scope.add_node root shared;
  Scope.add_node root source;
  Alcotest.(check (list int))
    "deduplicated ids" [ 1; 2 ] (collected_ids root)

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
          Alcotest.test_case "children include valid scope owner" `Quick
            test_children_with_scope_owner;
          Alcotest.test_case "context restores current" `Quick
            test_context_tracks_and_restores_current_scope;
          Alcotest.test_case "context restores after exception" `Quick
            test_context_restores_current_scope_after_exception;
          Alcotest.test_case "context requires valid current" `Quick
            test_require_valid_current_scope;
          Alcotest.test_case "validate accepts scoped nodes" `Quick
            test_validate_inner_accepts_unscoped_and_ancestor_scoped_nodes;
          Alcotest.test_case "validate rejects invalid nodes" `Quick
            test_validate_inner_rejects_invalid_nodes_and_scopes;
          Alcotest.test_case "validate traverses children" `Quick
            test_validate_inner_traverses_children_and_deduplicates;
          Alcotest.test_case "invalidation collects reachable nodes" `Quick
            test_invalidation_collects_dependents_and_nested_scope_nodes;
          Alcotest.test_case "invalidation excludes and skips invalid scope"
            `Quick
            test_invalidation_excludes_node_and_skips_invalid_nested_scope;
          Alcotest.test_case "invalidation deduplicates nodes" `Quick
            test_invalidation_deduplicates_reachable_nodes;
        ] );
    ]
