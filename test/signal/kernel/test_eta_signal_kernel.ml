module Kernel = Eta_signal_kernel

type node = {
  id : int;
  valid : bool;
  mutable version : int;
  mutable dirty : bool;
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

module Versions = Kernel.Make_versions (struct
  type id = int
  type nonrec packed = packed

  let id (P node) = node.id
  let equal_id = Int.equal
  let version (P node) = node.version
end)

module Dirty = Kernel.Make_dirty (struct
  type id = int
  type nonrec packed = packed

  let id (P node) = node.id
  let equal_id = Int.equal
  let dirty (P node) = node.dirty
  let set_dirty (P node) dirty = node.dirty <- dirty
end)

let node ?(valid = true) ?(version = 0) ?(dirty = false) id =
  { id; valid; version; dirty; dependencies = []; dependents = [] }

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

let test_versions_snapshot_preserves_order () =
  let left = node ~version:10 1 in
  let right = node ~version:20 2 in
  Alcotest.(check (list (pair int int))) "snapshot" [ (1, 10); (2, 20) ]
    (Versions.snapshot [ P left; P right ])

let test_versions_changed_detects_version_update () =
  let dependency = node ~version:1 1 in
  let current = Versions.snapshot [ P dependency ] in
  Alcotest.(check bool) "unchanged" false
    (Versions.changed ~current [ P dependency ]);
  dependency.version <- 2;
  Alcotest.(check bool) "changed" true
    (Versions.changed ~current [ P dependency ])

let test_versions_changed_detects_dependency_set_update () =
  let left = node 1 in
  let right = node 2 in
  let current = Versions.snapshot [ P left ] in
  Alcotest.(check bool) "changed" true
    (Versions.changed ~current [ P left; P right ])

let test_dirty_mark_sets_dirty () =
  let target = node 1 in
  Dirty.mark (P target);
  Alcotest.(check bool) "dirty" true target.dirty

let test_dirty_records_previous_state_once () =
  let target = node 1 in
  let entries = Dirty.mark_recording_previous [] (P target) in
  target.dirty <- false;
  let entries = Dirty.mark_recording_previous entries (P target) in
  Alcotest.(check int) "entry count" 1 (List.length entries);
  Alcotest.(check bool) "dirty" true target.dirty;
  Dirty.restore entries;
  Alcotest.(check bool) "restored" false target.dirty

let test_dirty_restore_preserves_initial_dirty () =
  let target = node ~dirty:true 1 in
  let entries = Dirty.mark_recording_previous [] (P target) in
  target.dirty <- false;
  Dirty.restore entries;
  Alcotest.(check bool) "restored" true target.dirty

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
      ( "versions",
        [
          Alcotest.test_case "snapshot preserves order" `Quick
            test_versions_snapshot_preserves_order;
          Alcotest.test_case "changed detects version update" `Quick
            test_versions_changed_detects_version_update;
          Alcotest.test_case "changed detects dependency set update" `Quick
            test_versions_changed_detects_dependency_set_update;
        ] );
      ( "dirty",
        [
          Alcotest.test_case "mark sets dirty" `Quick test_dirty_mark_sets_dirty;
          Alcotest.test_case "records previous state once" `Quick
            test_dirty_records_previous_state_once;
          Alcotest.test_case "restore preserves initial dirty" `Quick
            test_dirty_restore_preserves_initial_dirty;
        ] );
    ]
