module Kernel = Eta_signal_kernel

type node = {
  id : int;
  valid : bool;
  mutable version : int;
  mutable dirty : bool;
  mutable computing : bool;
  mutable seen_generation : int;
  mutable changed_seen : bool;
  mutable computed_generation : int;
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

module Compute = Kernel.Make_compute (struct
  type nonrec packed = packed
  type t = node

  let pack node = P node
  let seen_generation node = node.seen_generation
  let set_seen_generation node generation = node.seen_generation <- generation
  let changed_seen node = node.changed_seen
  let set_changed_seen node changed = node.changed_seen <- changed
  let computing node = node.computing
  let set_computing node computing = node.computing <- computing
  let computed_generation node = node.computed_generation

  let set_computed_generation node generation =
    node.computed_generation <- generation
end)

let node ?(valid = true) ?(version = 0) ?(dirty = false)
    ?(computing = false) ?(seen_generation = -1) ?(changed_seen = false)
    ?(computed_generation = -1) id =
  {
    id;
    valid;
    version;
    dirty;
    computing;
    seen_generation;
    changed_seen;
    computed_generation;
    dependencies = [];
    dependents = [];
  }

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

let test_compute_remember_records_once_per_generation () =
  let target = node 1 in
  let computed = Compute.remember ~generation:10 [] target in
  let computed = Compute.remember ~generation:10 computed target in
  Alcotest.(check (list int)) "computed" [ 1 ] (ids computed);
  Alcotest.(check int) "generation" 10 target.computed_generation

let test_compute_run_records_seen_generation_and_changed () =
  let target = node 1 in
  let value, changed =
    Compute.run ~generation:2 target
      ~cycle:(fun () -> failwith "unexpected cycle")
      ~compute:(fun () -> ("value", true))
  in
  Alcotest.(check string) "value" "value" value;
  Alcotest.(check bool) "changed" true changed;
  Alcotest.(check int) "seen generation" 2 target.seen_generation;
  Alcotest.(check bool) "changed seen" true target.changed_seen;
  Alcotest.(check bool) "computing reset" false target.computing

let test_compute_run_reports_cycle_without_resetting_existing_guard () =
  let target = node ~computing:true 1 in
  let value, changed =
    Compute.run ~generation:2 target
      ~cycle:(fun () -> ("cycle", false))
      ~compute:(fun () -> failwith "unexpected compute")
  in
  Alcotest.(check string) "value" "cycle" value;
  Alcotest.(check bool) "changed" false changed;
  Alcotest.(check bool) "computing preserved" true target.computing

let test_compute_run_resets_guard_after_exception () =
  let target = node 1 in
  let raised =
    try
      ignore
        (Compute.run ~generation:2 target
           ~cycle:(fun () -> failwith "unexpected cycle")
           ~compute:(fun () -> failwith "boom")
          : string * bool);
      false
    with Failure message -> String.equal message "boom"
  in
  Alcotest.(check bool) "raised" true raised;
  Alcotest.(check bool) "computing reset" false target.computing

let test_compute_seen_queries_generation_and_change_cache () =
  let target = node ~seen_generation:3 ~changed_seen:true 1 in
  Alcotest.(check bool) "seen current" true
    (Compute.seen ~generation:3 target);
  Alcotest.(check bool) "seen old" false (Compute.seen ~generation:4 target);
  Alcotest.(check bool) "changed seen" true (Compute.changed_seen target)

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
      ( "compute",
        [
          Alcotest.test_case "remember records once per generation" `Quick
            test_compute_remember_records_once_per_generation;
          Alcotest.test_case "run records seen generation and changed" `Quick
            test_compute_run_records_seen_generation_and_changed;
          Alcotest.test_case "run reports cycle" `Quick
            test_compute_run_reports_cycle_without_resetting_existing_guard;
          Alcotest.test_case "run resets guard after exception" `Quick
            test_compute_run_resets_guard_after_exception;
          Alcotest.test_case "seen queries generation and change cache" `Quick
            test_compute_seen_queries_generation_and_change_cache;
        ] );
    ]
