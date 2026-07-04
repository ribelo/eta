module Graph_algorithms = Eta_signal_graph_algorithms

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

module Edges = Graph_algorithms.Make_edges (struct
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

module Reachable = Graph_algorithms.Make_reachable (struct
  type id = int
  type nonrec packed = packed

  let id (P node) = node.id
  let valid (P node) = node.valid
  let children (P node) = node.dependencies
end)

module Order = Graph_algorithms.Make_order (struct
  type id = int
  type t = node

  let id node = node.id
  let equal_id = Int.equal
  let compare_id = Int.compare
  let children node = List.map (fun (P child) -> child) node.dependencies
end)

module Versions = Graph_algorithms.Make_versions (struct
  type id = int
  type nonrec packed = packed

  let id (P node) = node.id
  let equal_id = Int.equal
  let version (P node) = node.version
end)

module Dirty = Graph_algorithms.Make_dirty (struct
  type id = int
  type nonrec packed = packed

  let id (P node) = node.id
  let equal_id = Int.equal
  let dirty (P node) = node.dirty
  let set_dirty (P node) dirty = node.dirty <- dirty
end)

module Compute = Graph_algorithms.Make_compute (struct
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

let id_table ids =
  let table = Hashtbl.create 8 in
  List.iter (fun id -> Hashtbl.replace table id ()) ids;
  table

let demand_transitions transitions =
  transitions
  |> List.map (function
       | Graph_algorithms.Demand.Became_necessary id -> ("necessary", id)
       | Graph_algorithms.Demand.Became_unnecessary id -> ("unnecessary", id))
  |> List.sort compare

let demand_resource_states states =
  states
  |> List.map (fun state ->
         ( Graph_algorithms.Demand.resource_state_value state,
           Graph_algorithms.Demand.resource_state_necessary state ))

let demand_summary transitions =
  let summary = Graph_algorithms.Demand.summarize transitions in
  (summary.became_necessary, summary.became_unnecessary)

let demand_diff_summary ~previous ~next =
  let summary = Graph_algorithms.Demand.summarize_diff ~previous ~next in
  (summary.became_necessary, summary.became_unnecessary)

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

let test_demand_diff_reports_necessary_changes () =
  let previous = id_table [ 1; 2; 4 ] in
  let next = id_table [ 2; 3; 4 ] in
  let transitions = Graph_algorithms.Demand.diff ~previous ~next in
  Alcotest.(check (list (pair string int)))
    "transitions"
    [ ("necessary", 3); ("unnecessary", 1) ]
    (demand_transitions transitions);
  Alcotest.(check (pair int int)) "summary" (1, 1)
    (demand_summary transitions);
  Alcotest.(check (pair int int)) "diff summary" (1, 1)
    (demand_diff_summary ~previous ~next)

let test_demand_diff_ignores_stable_nodes () =
  let previous = id_table [ 1; 2 ] in
  let next = id_table [ 1; 2 ] in
  let transitions = Graph_algorithms.Demand.diff ~previous ~next in
  Alcotest.(check (list (pair string int))) "transitions" []
    (demand_transitions transitions);
  Alcotest.(check (pair int int)) "summary" (0, 0)
    (demand_summary transitions);
  Alcotest.(check (pair int int)) "diff summary" (0, 0)
    (demand_diff_summary ~previous ~next)

let test_demand_classifies_resources () =
  let resources =
    [
      Graph_algorithms.Demand.resource ~id:1 "cold";
      Graph_algorithms.Demand.resource ~id:2 "hot";
      Graph_algorithms.Demand.resource ~id:3 "warm";
    ]
  in
  Alcotest.(check (list (pair string bool)))
    "states"
    [ ("cold", false); ("hot", true); ("warm", true) ]
    (Graph_algorithms.Demand.classify_resources ~necessary:(id_table [ 2; 3 ])
       resources
    |> demand_resource_states)

let test_demand_classification_preserves_resource_order () =
  let resources =
    [
      Graph_algorithms.Demand.resource ~id:2 "first";
      Graph_algorithms.Demand.resource ~id:1 "second";
      Graph_algorithms.Demand.resource ~id:2 "third";
    ]
  in
  Alcotest.(check (list (pair string bool)))
    "states"
    [ ("first", true); ("second", false); ("third", true) ]
    (Graph_algorithms.Demand.classify_resources ~necessary:(id_table [ 2 ])
       resources
    |> demand_resource_states)

let test_order_dependencies_precede_dependents () =
  let dependent = node 3 in
  let dependency = node 1 in
  dependent.dependencies <- [ P dependency ];
  Alcotest.(check bool) "depends on" true
    (Order.depends_on dependent dependency);
  Alcotest.(check int) "dependent after dependency" 1
    (Order.compare dependent dependency);
  Alcotest.(check int) "dependency before dependent" (-1)
    (Order.compare dependency dependent)

let test_order_independent_nodes_use_id_order () =
  let left = node 1 in
  let right = node 3 in
  Alcotest.(check int) "left before right" (-1) (Order.compare left right);
  Alcotest.(check int) "right after left" 1 (Order.compare right left);
  Alcotest.(check int) "same node" 0 (Order.compare left left)

let test_order_handles_cycles_and_repeated_children () =
  let first = node 1 in
  let second = node 2 in
  let missing = node 3 in
  first.dependencies <- [ P second; P second ];
  second.dependencies <- [ P first ];
  Alcotest.(check bool) "cycle dependency" true
    (Order.depends_on first second);
  Alcotest.(check bool) "cycle terminates" false
    (Order.depends_on first missing)

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

let test_weak_cell_collect_keeps_matching_nodes () =
  let left = node 1 in
  let right = node ~valid:false 2 in
  let left_cell = Graph_algorithms.Weak_cell.create left in
  let right_cell = Graph_algorithms.Weak_cell.create right in
  let pack node = P node in
  let cells, packed =
    Graph_algorithms.Weak_cell.collect ~pack
      ~keep:(fun (P node) -> node.valid)
      [ left_cell; right_cell ]
  in
  Alcotest.(check int) "kept cells" 1 (List.length cells);
  Alcotest.(check (list int)) "kept nodes" [ 1 ] (ids packed);
  Alcotest.(check (option int))
    "cell value"
    (Some 1)
    (Option.map (fun (P node) -> node.id)
       (Graph_algorithms.Weak_cell.value ~pack left_cell))

let test_snapshot_publish_and_dependencies () =
  let empty = Graph_algorithms.Snapshot.empty in
  Alcotest.(check bool) "empty uninitialized" false
    (Graph_algorithms.Snapshot.is_initialized empty);
  Alcotest.(check (option int)) "empty value" None
    (Graph_algorithms.Snapshot.value empty);
  let first =
    Graph_algorithms.Snapshot.publish ~advance_version:succ ~current:empty empty 10
  in
  Alcotest.(check bool) "published initialized" true
    (Graph_algorithms.Snapshot.is_initialized first);
  Alcotest.(check (option int)) "published value" (Some 10)
    (Graph_algorithms.Snapshot.value first);
  Alcotest.(check int) "published version" 1
    (Graph_algorithms.Snapshot.version first);
  let staged = Graph_algorithms.Snapshot.with_version first 3 in
  let republished =
    Graph_algorithms.Snapshot.publish ~advance_version:succ ~current:first staged 20
  in
  Alcotest.(check int) "keeps advanced staged version" 3
    (Graph_algorithms.Snapshot.version republished);
  let dependencies =
    Graph_algorithms.Snapshot.with_dependency_versions republished [ (1, 5) ]
  in
  Alcotest.(check (list (pair int int))) "dependencies" [ (1, 5) ]
    (Graph_algorithms.Snapshot.dependency_versions dependencies)

let test_snapshot_preflight_commit_version () =
  let current = Graph_algorithms.Snapshot.initialized 1 in
  let staged = Graph_algorithms.Snapshot.with_version current 1 in
  let checked = ref [] in
  Graph_algorithms.Snapshot.preflight_commit_version
    ~advance_version:(fun version ->
      checked := version :: !checked;
      version + 1)
    ~current ~staged;
  Alcotest.(check (list int)) "checked current version" [ 0 ] !checked;
  checked := [];
  Graph_algorithms.Snapshot.preflight_commit_version
    ~advance_version:(fun version ->
      checked := version :: !checked;
      version + 1)
    ~current ~staged:current;
  Alcotest.(check (list int)) "unchanged skips" [] !checked

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

let test_value_cutoff_uninitialized_is_changed () =
  Alcotest.(check bool) "changed" true
    (Graph_algorithms.Value_cutoff.changed ~equal:Int.equal ~initialized:false
       ~current:(Some 1) ~next:1)

let test_value_cutoff_missing_current_is_changed () =
  Alcotest.(check bool) "changed" true
    (Graph_algorithms.Value_cutoff.changed ~equal:Int.equal ~initialized:true
       ~current:None ~next:1)

let test_value_cutoff_equal_value_is_unchanged () =
  Alcotest.(check bool) "unchanged" false
    (Graph_algorithms.Value_cutoff.changed ~equal:Int.equal ~initialized:true
       ~current:(Some 1) ~next:1)

let test_value_cutoff_unequal_value_is_changed () =
  Alcotest.(check bool) "changed" true
    (Graph_algorithms.Value_cutoff.changed ~equal:Int.equal ~initialized:true
       ~current:(Some 1) ~next:2)

let test_static_eval_map2_preserves_dependencies_and_output () =
  let left = Graph_algorithms.Static_eval.child ~dependency:"left" (2, false) in
  let right = Graph_algorithms.Static_eval.child ~dependency:"right" (3, true) in
  let result = Graph_algorithms.Static_eval.map2 left right ( + ) in
  Alcotest.(check (list string)) "dependencies" [ "left"; "right" ]
    (Graph_algorithms.Static_eval.dependencies result);
  Alcotest.(check int) "output" 5 (Graph_algorithms.Static_eval.output result);
  Alcotest.(check bool) "children changed" true
    (Graph_algorithms.Static_eval.children_changed result)

let test_static_eval_all_preserves_order () =
  let left = Graph_algorithms.Static_eval.child ~dependency:1 ("a", false) in
  let middle = Graph_algorithms.Static_eval.child ~dependency:2 ("b", false) in
  let right = Graph_algorithms.Static_eval.child ~dependency:3 ("c", false) in
  let result = Graph_algorithms.Static_eval.all [ left; middle; right ] in
  Alcotest.(check (list int)) "dependencies" [ 1; 2; 3 ]
    (Graph_algorithms.Static_eval.dependencies result);
  Alcotest.(check (list string)) "output" [ "a"; "b"; "c" ]
    (Graph_algorithms.Static_eval.output result);
  Alcotest.(check bool) "children changed" false
    (Graph_algorithms.Static_eval.children_changed result)

let test_static_eval_recompute_predicate () =
  let clean = Graph_algorithms.Static_eval.leaf 1 in
  let changed_child =
    Graph_algorithms.Static_eval.map
      (Graph_algorithms.Static_eval.child ~dependency:"dep" (1, true))
      succ
  in
  let dependencies_changed dependencies =
    List.exists (String.equal "changed") dependencies
  in
  Alcotest.(check bool) "clean" false
    (Graph_algorithms.Static_eval.should_recompute ~dirty:false ~initialized:true
       ~dependencies_changed clean);
  Alcotest.(check bool) "dirty" true
    (Graph_algorithms.Static_eval.should_recompute ~dirty:true ~initialized:true
       ~dependencies_changed clean);
  Alcotest.(check bool) "uninitialized" true
    (Graph_algorithms.Static_eval.should_recompute ~dirty:false ~initialized:false
       ~dependencies_changed clean);
  Alcotest.(check bool) "child changed" true
    (Graph_algorithms.Static_eval.should_recompute ~dirty:false ~initialized:true
       ~dependencies_changed changed_child);
  let changed_dependency =
    Graph_algorithms.Static_eval.map
      (Graph_algorithms.Static_eval.child ~dependency:"changed" (1, false))
      succ
  in
  Alcotest.(check bool) "dependency changed" true
    (Graph_algorithms.Static_eval.should_recompute ~dirty:false ~initialized:true
       ~dependencies_changed changed_dependency)

let test_static_eval_plan_reuses_without_forcing_output () =
  let ran = ref false in
  let child = Graph_algorithms.Static_eval.child ~dependency:"dep" (1, false) in
  let result =
    Graph_algorithms.Static_eval.map child (fun value ->
        ran := true;
        value + 1)
  in
  let plan =
    Graph_algorithms.Static_eval.plan ~dirty:false ~initialized:true
      ~dependencies_changed:(fun _ -> false)
      result
  in
  (match plan with
  | Graph_algorithms.Static_eval.Use_cached -> ()
  | Graph_algorithms.Static_eval.Recompute _ -> Alcotest.fail "expected cached plan");
  Alcotest.(check bool) "output not forced" false !ran

let test_static_eval_plan_recomputes_with_dependencies_and_output () =
  let ran = ref false in
  let child = Graph_algorithms.Static_eval.child ~dependency:"dep" (1, true) in
  let result =
    Graph_algorithms.Static_eval.map child (fun value ->
        ran := true;
        value + 1)
  in
  match
    Graph_algorithms.Static_eval.plan ~dirty:false ~initialized:true
      ~dependencies_changed:(fun _ -> false)
      result
  with
  | Graph_algorithms.Static_eval.Use_cached -> Alcotest.fail "expected recompute plan"
  | Graph_algorithms.Static_eval.Recompute
      { dependencies; output; stage_dependencies } ->
      Alcotest.(check (list string)) "dependencies" [ "dep" ] dependencies;
      Alcotest.(check int) "output" 2 output;
      Alcotest.(check bool) "stage dependencies" true stage_dependencies;
      Alcotest.(check bool) "output forced" true !ran

let test_static_eval_plan_can_skip_dependency_staging () =
  match
    Graph_algorithms.Static_eval.plan ~stage_dependencies:false ~dirty:true
      ~initialized:true ~dependencies_changed:(fun _ -> false)
      (Graph_algorithms.Static_eval.leaf "value")
  with
  | Graph_algorithms.Static_eval.Use_cached -> Alcotest.fail "expected recompute plan"
  | Graph_algorithms.Static_eval.Recompute
      { dependencies; output; stage_dependencies } ->
      Alcotest.(check (list string)) "dependencies" [] dependencies;
      Alcotest.(check string) "output" "value" output;
      Alcotest.(check bool) "stage dependencies" false stage_dependencies

let test_static_eval_delays_output_until_requested () =
  let ran = ref false in
  let child = Graph_algorithms.Static_eval.child ~dependency:"dep" (1, false) in
  let result =
    Graph_algorithms.Static_eval.map child (fun value ->
        ran := true;
        value + 1)
  in
  let dependencies_changed _ = false in
  ignore
    (Graph_algorithms.Static_eval.should_recompute ~dirty:false ~initialized:true
       ~dependencies_changed result
      : bool);
  Alcotest.(check bool) "not forced by predicate" false !ran;
  Alcotest.(check int) "output" 2 (Graph_algorithms.Static_eval.output result);
  Alcotest.(check bool) "forced by output" true !ran

let () =
  Alcotest.run "eta_signal_graph_algorithms"
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
      ( "demand",
        [
          Alcotest.test_case "diff reports necessary changes" `Quick
            test_demand_diff_reports_necessary_changes;
          Alcotest.test_case "diff ignores stable nodes" `Quick
            test_demand_diff_ignores_stable_nodes;
          Alcotest.test_case "classifies resources" `Quick
            test_demand_classifies_resources;
          Alcotest.test_case "classification preserves resource order" `Quick
            test_demand_classification_preserves_resource_order;
        ] );
      ( "order",
        [
          Alcotest.test_case "dependencies precede dependents" `Quick
            test_order_dependencies_precede_dependents;
          Alcotest.test_case "independent nodes use id order" `Quick
            test_order_independent_nodes_use_id_order;
          Alcotest.test_case "handles cycles and repeated children" `Quick
            test_order_handles_cycles_and_repeated_children;
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
      ( "weak_cell",
        [
          Alcotest.test_case "collect keeps matching nodes" `Quick
            test_weak_cell_collect_keeps_matching_nodes;
        ] );
      ( "snapshot",
        [
          Alcotest.test_case "publish and dependencies" `Quick
            test_snapshot_publish_and_dependencies;
          Alcotest.test_case "preflight commit version" `Quick
            test_snapshot_preflight_commit_version;
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
      ( "value_cutoff",
        [
          Alcotest.test_case "uninitialized is changed" `Quick
            test_value_cutoff_uninitialized_is_changed;
          Alcotest.test_case "missing current is changed" `Quick
            test_value_cutoff_missing_current_is_changed;
          Alcotest.test_case "equal value is unchanged" `Quick
            test_value_cutoff_equal_value_is_unchanged;
          Alcotest.test_case "unequal value is changed" `Quick
            test_value_cutoff_unequal_value_is_changed;
        ] );
      ( "static_eval",
        [
          Alcotest.test_case "map2 preserves dependencies and output" `Quick
            test_static_eval_map2_preserves_dependencies_and_output;
          Alcotest.test_case "all preserves order" `Quick
            test_static_eval_all_preserves_order;
          Alcotest.test_case "recompute predicate" `Quick
            test_static_eval_recompute_predicate;
          Alcotest.test_case "plan reuses without forcing output" `Quick
            test_static_eval_plan_reuses_without_forcing_output;
          Alcotest.test_case
            "plan recomputes with dependencies and output" `Quick
            test_static_eval_plan_recomputes_with_dependencies_and_output;
          Alcotest.test_case "plan can skip dependency staging" `Quick
            test_static_eval_plan_can_skip_dependency_staging;
          Alcotest.test_case "delays output until requested" `Quick
            test_static_eval_delays_output_until_requested;
        ] );
    ]
