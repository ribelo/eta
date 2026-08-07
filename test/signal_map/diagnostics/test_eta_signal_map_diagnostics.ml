module E = Eta.Effect

module Harness () = struct
  module S = Eta_signal_map_api.Make (Eta_signal.No_observer_error) ()

  module Order = struct
    type t = int
    let compare = Int.compare
  end

  module M = Eta_signal_map_api.Map.Make (Order)
  module K = S.Keyed (Order)
  module T = K.Testing

  type error = [ S.graph_error | S.observer_read_error | S.stabilize_error ]

  let widen (eff : ('a, [< error ]) E.t) : ('a, error) E.t =
    E.map_error (fun error -> (error :> error)) eff

  let run_ok runtime eff =
    Eta_test.Expect.expect_ok (Eta.Runtime.run runtime (widen eff))

  let run_exit runtime eff = Eta.Runtime.run runtime (widen eff)

  let observe runtime signal callback =
    run_ok runtime (S.Observer.observe signal ~on_update:callback)

  let stabilize runtime = run_ok runtime S.stabilize
  let set runtime source value = run_ok runtime (S.Var.set source value)
  let read runtime observer = run_ok runtime (S.Observer.read observer)
  let stats runtime = run_ok runtime (S.stats ())
  let dot runtime options = run_ok runtime (S.to_dot ~options ())
  let dispose runtime observer = run_ok runtime (S.Observer.dispose observer)
end

let contains haystack needle =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec loop index =
    index + needle_length <= haystack_length
    &&
    (String.sub haystack index needle_length = needle || loop (index + 1))
  in
  needle_length = 0 || loop 0

let count_substring text needle =
  let rec loop index count =
    if index + String.length needle > String.length text then count
    else if String.sub text index (String.length needle) = needle then
      loop (index + String.length needle) (count + 1)
    else loop (index + 1) count
  in
  if String.length needle = 0 then 0 else loop 0 0

let test_keyed_stats_zero_without_keyed_nodes () =
  let module H = Harness () in
  let module Plain = Eta_signal.Make_no_error () in
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let plain_stats =
    Plain.stats ()
    |> E.map_error (fun error -> (error :> H.error))
    |> Eta.Runtime.run runtime
    |> Eta_test.Expect.expect_ok
  in
  let plain = plain_stats.keyed in
  Alcotest.(check (list int)) "plain keyed zeros"
    (List.init 10 (fun _ -> 0))
    [
      plain.node_count;
      plain.committed_child_count;
      plain.reconciliation_count;
      plain.input_key_comparison_count;
      plain.input_diff_event_count;
      plain.child_visit_count;
      plain.provisional_addition_count;
      plain.committed_addition_count;
      plain.committed_removal_count;
      plain.reconciliation_rollback_count;
    ];
  let unused = (H.stats runtime).keyed in
  Alcotest.(check (list int)) "unused map keyed zeros"
    (List.init 10 (fun _ -> 0))
    [
      unused.node_count;
      unused.committed_child_count;
      unused.reconciliation_count;
      unused.input_key_comparison_count;
      unused.input_diff_event_count;
      unused.child_visit_count;
      unused.provisional_addition_count;
      unused.committed_addition_count;
      unused.committed_removal_count;
      unused.reconciliation_rollback_count;
    ]

let test_keyed_stats_live_gauges_follow_committed_state () =
  let module H = Harness () in
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let input = H.S.Var.create H.M.empty in
  let output = H.K.mapi (H.S.Var.watch input) ~f:(fun ~key:_ ~data -> data) in
  let observer = H.observe runtime output (fun _ -> E.unit) in
  H.stabilize runtime;
  let empty = H.stats runtime in
  Alcotest.(check int) "one keyed node" 1 empty.keyed.node_count;
  Alcotest.(check int) "no children" 0 empty.keyed.committed_child_count;
  let two = H.M.set 2 20 (H.M.set 1 10 H.M.empty) in
  let before_additions = empty.keyed.provisional_addition_count in
  H.set runtime input two;
  H.stabilize runtime;
  let added = H.stats runtime in
  Alcotest.(check int) "two children" 2 added.keyed.committed_child_count;
  Alcotest.(check int) "two provisional scopes" 2
    (added.keyed.provisional_addition_count - before_additions);
  let before_removal = added.keyed.provisional_addition_count in
  H.set runtime input (H.M.remove 1 two);
  H.stabilize runtime;
  let removed = H.stats runtime in
  Alcotest.(check int) "one child" 1 removed.keyed.committed_child_count;
  Alcotest.(check int) "removal registers no provisional scope" 0
    (removed.keyed.provisional_addition_count - before_removal);
  H.dispose runtime observer

let map_of_size empty set size =
  let map = ref empty in
  for key = 0 to size - 1 do
    map := set key (ref key) !map
  done;
  !map

let test_keyed_stats_report_shared_and_independent_diff_work () =
  let module H = Harness () in
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let initial = map_of_size H.M.empty H.M.set 1023 in
  let input = H.S.Var.create initial in
  let output =
    H.K.mapi (H.S.Var.watch input) ~f:(fun ~key:_ ~data ->
        H.S.map ( ! ) data)
  in
  let observer = H.observe runtime output (fun _ -> E.unit) in
  H.stabilize runtime;
  let before_shared = (H.stats runtime).keyed in
  H.set runtime input (H.M.set 1022 (ref 7) initial);
  H.stabilize runtime;
  let after_shared = (H.stats runtime).keyed in
  let shared_comparisons =
    after_shared.input_key_comparison_count
    - before_shared.input_key_comparison_count
  in
  Alcotest.(check int) "shared one event" 1
    (after_shared.input_diff_event_count - before_shared.input_diff_event_count);
  Alcotest.(check bool) "shared change proportional" true (shared_comparisons < 100);
  let independent =
    H.M.to_list (H.M.set 1022 (ref 8) initial)
    |> H.M.of_list |> Result.get_ok
  in
  let before_independent = (H.stats runtime).keyed in
  H.set runtime input independent;
  H.stabilize runtime;
  let after_independent = (H.stats runtime).keyed in
  let independent_comparisons =
    after_independent.input_key_comparison_count
    - before_independent.input_key_comparison_count
  in
  Alcotest.(check int) "independent one event" 1
    (after_independent.input_diff_event_count
     - before_independent.input_diff_event_count);
  Alcotest.(check bool) "independent linear" true (independent_comparisons >= 1023);
  H.dispose runtime observer

let test_keyed_stats_report_affected_child_visits () =
  let module H = Harness () in
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let locals = Hashtbl.create 1023 in
  let initial = map_of_size H.M.empty H.M.set 1023 in
  let input = H.S.Var.create initial in
  let output =
    H.K.mapi (H.S.Var.watch input) ~f:(fun ~key ~data ->
        let local = H.S.Var.create 0 in
        Hashtbl.add locals key local;
        H.S.map2 (fun data local -> !data + local) data (H.S.Var.watch local))
  in
  let observer = H.observe runtime output (fun _ -> E.unit) in
  H.stabilize runtime;
  let before = (H.stats runtime).keyed.child_visit_count in
  List.iter (fun key -> H.set runtime (Hashtbl.find locals key) 1) [ 3; 400; 1000 ];
  H.stabilize runtime;
  let after = (H.stats runtime).keyed.child_visit_count in
  Alcotest.(check int) "three affected visits" 3 (after - before);
  H.dispose runtime observer

let test_keyed_stats_count_failed_attempt_and_rollback () =
  let module H = Harness () in
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let fail_builder = ref false in
  let fail_cutoff = ref false in
  let input = H.S.Var.create H.M.empty in
  let output =
    H.K.mapi
      ~data_cutoff:
        (Eta_signal.Cutoff.of_equal (fun _ _ ->
           if !fail_cutoff then failwith "cutoff";
           false))
      (H.S.Var.watch input) ~f:(fun ~key:_ ~data ->
        if !fail_builder then failwith "builder";
        data)
  in
  let observer = H.observe runtime output (fun _ -> E.unit) in
  H.stabilize runtime;
  let baseline = (H.stats runtime).keyed in
  fail_builder := true;
  H.set runtime input (H.M.set 1 (ref 1) H.M.empty);
  ignore (H.run_exit runtime H.S.stabilize);
  fail_builder := false;
  H.stabilize runtime;
  fail_cutoff := true;
  H.set runtime input (H.M.set 1 (ref 2) H.M.empty);
  ignore (H.run_exit runtime H.S.stabilize);
  fail_cutoff := false;
  H.T.set_preflight output (fun () -> failwith "preflight");
  H.set runtime input (H.M.set 2 (ref 2) H.M.empty);
  ignore (H.run_exit runtime H.S.stabilize);
  H.T.set_preflight output (fun () -> ());
  let after = (H.stats runtime).keyed in
  Alcotest.(check int) "four reconciliation attempts" 4
    (after.reconciliation_count - baseline.reconciliation_count);
  Alcotest.(check int) "three rollbacks" 3
    (after.reconciliation_rollback_count - baseline.reconciliation_rollback_count);
  Alcotest.(check int) "one committed addition" 1
    (after.committed_addition_count - baseline.committed_addition_count);
  Alcotest.(check int) "no committed removal" 0
    (after.committed_removal_count - baseline.committed_removal_count);
  Alcotest.(check int) "one live child" 1 after.committed_child_count;
  Alcotest.(check int) "two registered provisional scopes" 2
    (after.provisional_addition_count - baseline.provisional_addition_count);
  H.dispose runtime observer

let test_keyed_stats_count_each_rolled_back_plan () =
  let module H = Harness () in
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let first_input = H.S.Var.create H.M.empty in
  let second_input = H.S.Var.create H.M.empty in
  let keyed input =
    H.K.mapi (H.S.Var.watch input) ~f:(fun ~key:_ ~data -> data)
  in
  let first = keyed first_input in
  let second = keyed second_input in
  let fail_downstream = ref false in
  let combined =
    H.S.map2
      (fun first second ->
        if !fail_downstream then failwith "downstream";
        H.M.cardinal first + H.M.cardinal second)
      first second
  in
  let observer = H.observe runtime combined (fun _ -> E.unit) in
  H.stabilize runtime;
  let before = (H.stats runtime).keyed in
  fail_downstream := true;
  H.set runtime first_input (H.M.set 1 10 H.M.empty);
  H.set runtime second_input (H.M.set 2 20 H.M.empty);
  ignore (H.run_exit runtime H.S.stabilize);
  let after = (H.stats runtime).keyed in
  Alcotest.(check int) "two plans rolled back" 2
    (after.reconciliation_rollback_count
     - before.reconciliation_rollback_count);
  Alcotest.(check int) "failed additions not committed" 0
    (after.committed_addition_count - before.committed_addition_count);
  Alcotest.(check int) "no live children after rollback" 0
    after.committed_child_count;
  H.dispose runtime observer

let test_keyed_stats_commit_transitions_only_after_commit () =
  let module H = Harness () in
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let fail_callback = ref false in
  let input = H.S.Var.create H.M.empty in
  let output = H.K.mapi (H.S.Var.watch input) ~f:(fun ~key:_ ~data -> data) in
  let observer =
    H.observe runtime output (fun _ ->
        if !fail_callback then E.sync (fun () -> failwith "callback") else E.unit)
  in
  H.stabilize runtime;
  let before = (H.stats runtime).keyed in
  H.set runtime input (H.M.set 1 10 H.M.empty);
  let staged_only = (H.stats runtime).keyed in
  Alcotest.(check int) "not committed before stabilization"
    before.committed_addition_count staged_only.committed_addition_count;
  fail_callback := true;
  ignore (H.run_exit runtime H.S.stabilize);
  let committed = (H.stats runtime).keyed in
  Alcotest.(check int) "commit survives callback failure" 1
    (committed.committed_addition_count - before.committed_addition_count);
  fail_callback := false;
  H.dispose runtime observer

let test_keyed_stats_saturation_does_not_change_transaction () =
  let counters = List.init 8 Fun.id in
  List.iter
    (fun selected ->
      let module H = Harness () in
      Eta_test.with_test_clock @@ fun _switch _clock runtime ->
      let input = H.S.Var.create H.M.empty in
      let output = H.K.mapi (H.S.Var.watch input) ~f:(fun ~key:_ ~data -> data) in
      let observer = H.observe runtime output (fun _ -> E.unit) in
      H.stabilize runtime;
      let counter =
        match selected with
        | 0 -> H.T.Reconciliation_count
        | 1 -> H.T.Input_key_comparison_count
        | 2 -> H.T.Input_diff_event_count
        | 3 -> H.T.Child_visit_count
        | 4 -> H.T.Provisional_addition_count
        | 5 -> H.T.Committed_addition_count
        | 6 -> H.T.Committed_removal_count
        | _ -> H.T.Reconciliation_rollback_count
      in
      let counter_name =
        match selected with
        | 0 -> "stats keyed.reconciliation_count"
        | 1 -> "stats keyed.input_key_comparison_count"
        | 2 -> "stats keyed.input_diff_event_count"
        | 3 -> "stats keyed.child_visit_count"
        | 4 -> "stats keyed.provisional_addition_count"
        | 5 -> "stats keyed.committed_addition_count"
        | 6 -> "stats keyed.committed_removal_count"
        | _ -> "stats keyed.reconciliation_rollback_count"
      in
      H.T.set_counter counter max_int;
      H.set runtime input (H.M.set 1 10 H.M.empty);
      H.stabilize runtime;
      Alcotest.(check (option int)) "transaction still commits" (Some 10)
        (H.M.find_opt 1 (H.read runtime observer));
      (match H.run_exit runtime (H.S.stats ()) with
       | Eta.Exit.Error (Eta.Cause.Fail (`Counter_overflow actual)) ->
           Alcotest.(check string) "overflow target" counter_name actual
       | Eta.Exit.Error _ | Eta.Exit.Ok _ ->
           Alcotest.fail "expected keyed counter overflow");
      H.dispose runtime observer)
    counters

let test_keyed_dot_scope_selection_shows_keyed_nodes () =
  let module H = Harness () in
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let input = H.S.Var.create (H.M.set 1 10 H.M.empty) in
  let output = H.K.mapi (H.S.Var.watch input) ~f:(fun ~key:_ ~data -> data) in
  let necessary = H.S.{ default_dot_options with dot_scope = `Necessary } in
  let all_valid = H.S.{ default_dot_options with dot_scope = `All_valid } in
  let all_invalid =
    H.S.{ default_dot_options with dot_scope = `All_including_invalid }
  in
  Alcotest.(check bool) "unused absent from necessary" false
    (contains (H.dot runtime necessary) "kind=keyed_mapi");
  Alcotest.(check bool) "unused present in all valid" true
    (contains (H.dot runtime all_valid) "kind=keyed_mapi");
  let observer = H.observe runtime output (fun _ -> E.unit) in
  H.stabilize runtime;
  Alcotest.(check bool) "demanded present in necessary" true
    (contains (H.dot runtime necessary) "kind=keyed_mapi");
  H.dispose runtime observer;
  let active = H.S.Var.create true in
  let dynamic =
    H.S.bind (H.S.Var.watch active) ~f:(fun active ->
        if active then
          H.K.mapi (H.S.Var.watch input) ~f:(fun ~key:_ ~data -> data)
        else H.S.const H.M.empty)
  in
  let dynamic_observer = H.observe runtime dynamic (fun _ -> E.unit) in
  H.stabilize runtime;
  H.set runtime active false;
  H.stabilize runtime;
  let valid_count =
    count_substring (H.dot runtime all_valid) "kind=keyed_mapi"
  in
  let including_invalid_count =
    count_substring (H.dot runtime all_invalid) "kind=keyed_mapi"
  in
  Alcotest.(check bool) "invalid keyed tombstone included" true
    (including_invalid_count > valid_count);
  H.dispose runtime dynamic_observer

let test_keyed_dot_dynamic_scopes_show_committed_children () =
  let module H = Harness () in
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let input = H.S.Var.create (H.M.set 1 10 H.M.empty) in
  let output = H.K.mapi (H.S.Var.watch input) ~f:(fun ~key:_ ~data -> data) in
  let observer = H.observe runtime output (fun _ -> E.unit) in
  H.stabilize runtime;
  let options =
    H.S.
      {
        default_dot_options with
        dot_scope = `All_valid;
        dot_state = true;
        dot_dynamic_scopes = true;
      }
  in
  let dot = H.dot runtime options in
  List.iter
    (fun field -> Alcotest.(check bool) field true (contains dot field))
    [
      "kind=keyed_mapi";
      "committed_children=1";
      "requested_scope=all_valid";
      "scope_owner=s";
      ":valid";
    ];
  H.dispose runtime observer

let test_keyed_dot_invalid_tombstones_are_bounded_and_value_free () =
  let module H = Harness () in
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let sentinel = "KEYED_SECRET_SENTINEL" in
  let input = H.S.Var.create H.M.empty in
  let output =
    H.K.mapi (H.S.Var.watch input) ~f:(fun ~key:_ ~data ->
        H.S.map String.uppercase_ascii data)
  in
  let observer = H.observe runtime output (fun _ -> E.unit) in
  H.stabilize runtime;
  for key = 0 to 1029 do
    H.set runtime input (H.M.set key sentinel H.M.empty);
    H.stabilize runtime;
    H.set runtime input H.M.empty;
    H.stabilize runtime
  done;
  let options =
    H.S.{ default_dot_options with dot_scope = `All_including_invalid }
  in
  let dot = H.dot runtime options in
  Alcotest.(check bool) "no key or data sentinel" false (contains dot sentinel);
  Alcotest.(check bool) "no key metadata" false (contains dot "key=");
  Alcotest.(check bool) "contains invalid tombstones" true
    (count_substring dot "tombstone=true" > 0);
  Alcotest.(check bool) "bounded tombstones" true
    (count_substring dot "tombstone=true" <= 1024);
  H.dispose runtime observer

let test_keyed_diagnostics_are_read_only () =
  let module H = Harness () in
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let input = H.S.Var.create (H.M.set 1 10 H.M.empty) in
  let output = H.K.mapi (H.S.Var.watch input) ~f:(fun ~key:_ ~data -> data) in
  let observer = H.observe runtime output (fun _ -> E.unit) in
  H.stabilize runtime;
  let before = H.stats runtime in
  let identity_before = H.T.entry_identity output 1 |> Option.get in
  ignore (H.stats runtime);
  ignore (H.dot runtime H.S.default_dot_options);
  let after_reads = H.stats runtime in
  Alcotest.(check int) "reconciliation unchanged"
    before.keyed.reconciliation_count after_reads.keyed.reconciliation_count;
  Alcotest.(check int) "visits unchanged"
    before.keyed.child_visit_count after_reads.keyed.child_visit_count;
  let identity_after = H.T.entry_identity output 1 |> Option.get in
  Alcotest.(check bool) "identity unchanged" true
    (identity_before.keyed_scope_token == identity_after.keyed_scope_token);
  H.set runtime input (H.M.set 1 20 H.M.empty);
  ignore (H.stats runtime);
  ignore (H.dot runtime H.S.default_dot_options);
  H.stabilize runtime;
  Alcotest.(check (option int)) "transition unchanged" (Some 20)
    (H.M.find_opt 1 (H.read runtime observer));
  H.dispose runtime observer

let () =
  Alcotest.run "eta_signal_map_diagnostics"
    [
      ( "diagnostics",
        [
          Alcotest.test_case "test_keyed_stats_zero_without_keyed_nodes" `Quick
            test_keyed_stats_zero_without_keyed_nodes;
          Alcotest.test_case
            "test_keyed_stats_live_gauges_follow_committed_state" `Quick
            test_keyed_stats_live_gauges_follow_committed_state;
          Alcotest.test_case
            "test_keyed_stats_report_shared_and_independent_diff_work" `Quick
            test_keyed_stats_report_shared_and_independent_diff_work;
          Alcotest.test_case "test_keyed_stats_report_affected_child_visits"
            `Quick test_keyed_stats_report_affected_child_visits;
          Alcotest.test_case "test_keyed_stats_count_failed_attempt_and_rollback"
            `Quick test_keyed_stats_count_failed_attempt_and_rollback;
          Alcotest.test_case "test_keyed_stats_count_each_rolled_back_plan"
            `Quick test_keyed_stats_count_each_rolled_back_plan;
          Alcotest.test_case
            "test_keyed_stats_commit_transitions_only_after_commit" `Quick
            test_keyed_stats_commit_transitions_only_after_commit;
          Alcotest.test_case
            "test_keyed_stats_saturation_does_not_change_transaction" `Quick
            test_keyed_stats_saturation_does_not_change_transaction;
          Alcotest.test_case "test_keyed_dot_scope_selection_shows_keyed_nodes"
            `Quick test_keyed_dot_scope_selection_shows_keyed_nodes;
          Alcotest.test_case
            "test_keyed_dot_dynamic_scopes_show_committed_children" `Quick
            test_keyed_dot_dynamic_scopes_show_committed_children;
          Alcotest.test_case
            "test_keyed_dot_invalid_tombstones_are_bounded_and_value_free" `Quick
            test_keyed_dot_invalid_tombstones_are_bounded_and_value_free;
          Alcotest.test_case "test_keyed_diagnostics_are_read_only" `Quick
            test_keyed_diagnostics_are_read_only;
        ] );
    ]
