module Kernel = Eta_signal_kernel

type node = {
  id : int;
  valid : bool;
  mutable dependencies : packed list;
  mutable dependents : packed list;
}

and packed = P of node

module Edges = Kernel.Make_edges (struct
  type id = int
  type nonrec packed = packed
  type t = node

  let pack node = P node
  let unpack (P node) = node
  let id node = node.id
  let equal_id = Int.equal
  let dependencies node = node.dependencies
  let set_dependencies node dependencies = node.dependencies <- dependencies
  let dependents node = node.dependents
  let set_dependents node dependents = node.dependents <- dependents
end)

module Reachable = Kernel.Make_reachable (struct
  type id = int
  type nonrec packed = packed

  let id (P node) = node.id
  let valid (P node) = node.valid
  let children (P node) = node.dependencies
end)

let node ?(valid = true) id = { id; valid; dependencies = []; dependents = [] }
let ids packed = List.map (fun (P node) -> node.id) packed
let sorted_ids ids = List.sort Int.compare ids

let reachable_ids table =
  Hashtbl.to_seq_keys table |> List.of_seq |> sorted_ids

let test_attach_is_bidirectional_and_idempotent () =
  let parent = node 1 in
  let child = node 2 in
  Edges.attach_dependency ~parent ~child;
  Edges.attach_dependency ~parent ~child;
  Alcotest.(check (list int)) "parent dependencies" [ 2 ]
    (ids parent.dependencies);
  Alcotest.(check (list int)) "child dependents" [ 1 ]
    (ids child.dependents);
  Alcotest.(check bool) "has dependency" true
    (Edges.has_dependency ~parent ~child);
  Alcotest.(check bool) "has dependent" true
    (Edges.has_dependent ~child ~parent)

let test_detach_removes_both_edges () =
  let parent = node 1 in
  let child = node 2 in
  Edges.attach_dependency ~parent ~child;
  Edges.detach_dependency ~parent ~child;
  Alcotest.(check (list int)) "parent dependencies" [] (ids parent.dependencies);
  Alcotest.(check (list int)) "child dependents" [] (ids child.dependents)

let test_attach_packed_dependency () =
  let parent = node 1 in
  let child = node 2 in
  Edges.attach_packed_dependency ~parent (P child);
  Alcotest.(check (list int)) "parent dependencies" [ 2 ]
    (ids parent.dependencies);
  Alcotest.(check (list int)) "child dependents" [ 1 ] (ids child.dependents)

let test_reachable_ids_skip_invalid_and_deduplicate () =
  let root = node 1 in
  let child = node 2 in
  let grandchild = node 3 in
  let invalid = node ~valid:false 4 in
  let hidden = node 5 in
  root.dependencies <- [ P child; P child; P invalid ];
  child.dependencies <- [ P grandchild; P root ];
  invalid.dependencies <- [ P hidden ];
  Alcotest.(check (list int)) "reachable ids" [ 1; 2; 3 ]
    (reachable_ids (Reachable.ids ~roots:[ P root ]))

let test_reachable_fold_visits_multiple_roots () =
  let left = node 1 in
  let right = node 2 in
  let shared = node 3 in
  left.dependencies <- [ P shared ];
  right.dependencies <- [ P shared ];
  let visited =
    Reachable.fold ~roots:[ P left; P right ] ~init:[]
      ~f:(fun visited (P node) -> node.id :: visited)
    |> sorted_ids
  in
  Alcotest.(check (list int)) "visited" [ 1; 2; 3 ] visited

let () =
  Alcotest.run "eta_signal_kernel"
    [
      ( "edges",
        [
          Alcotest.test_case "attach is bidirectional and idempotent" `Quick
            test_attach_is_bidirectional_and_idempotent;
          Alcotest.test_case "detach removes both edges" `Quick
            test_detach_removes_both_edges;
          Alcotest.test_case "attach packed dependency" `Quick
            test_attach_packed_dependency;
        ] );
      ( "reachable",
        [
          Alcotest.test_case "ids skip invalid and deduplicate" `Quick
            test_reachable_ids_skip_invalid_and_deduplicate;
          Alcotest.test_case "fold visits multiple roots" `Quick
            test_reachable_fold_visits_multiple_roots;
        ] );
    ]
