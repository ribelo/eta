module Kernel = Eta_signal_kernel

type node = {
  id : int;
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

let node id = { id; dependencies = []; dependents = [] }
let ids packed = List.map (fun (P node) -> node.id) packed

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
    ]
