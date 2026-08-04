module E = Eta.Effect
module S = Eta_signal_map_api.Make (Eta_signal.No_observer_error) ()

module Order = struct
  type t = int

  let compare = Int.compare
end

module M = Eta_signal_map_api.Map.Make (Order)
module K = S.Keyed (Order)
module T = K.Testing

type test_error = [ S.graph_error | S.observer_read_error | S.stabilize_error ]

let widen (eff : ('a, [< test_error ]) E.t) : ('a, test_error) E.t =
  E.map_error (fun error -> (error :> test_error)) eff

let run_ok runtime eff =
  Eta_test.Expect.expect_ok (Eta.Runtime.run runtime (widen eff))

let run_exit runtime eff = Eta.Runtime.run runtime (widen eff)

let expect_defect label = function
  | Eta.Exit.Error (Eta.Cause.Die _) -> ()
  | Eta.Exit.Error _ -> Alcotest.failf "%s: expected defect" label
  | Eta.Exit.Ok _ -> Alcotest.failf "%s: expected failure" label

let test_keyed_mapi_commit_removes_before_additions () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let input = S.Var.create (M.set 1 10 M.empty) in
  let output = K.mapi (S.Var.watch input) ~f:(fun ~key:_ ~data -> data) in
  let events = ref [] in
  T.set_event_recorder output (fun event -> events := !events @ [ event ]);
  let observer = run_ok runtime (S.Observer.observe output (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  events := [];
  let removed =
    match T.entry_identity output 1 with
    | Some identity -> identity
    | None -> Alcotest.fail "missing committed entry"
  in
  run_ok runtime (S.Var.set input (M.set 2 20 M.empty));
  run_ok runtime S.stabilize;
  (match !events with
   | [ T.Detached detached; T.Invalidated invalidated; T.Attached _ ] ->
       Alcotest.(check bool) "detached exact scope" true
         (detached == removed.keyed_scope_token);
       Alcotest.(check bool) "invalidated exact scope" true
         (invalidated == removed.keyed_scope_token)
   | events ->
       let labels =
         List.map
           (function
             | T.Detached _ -> "detached"
             | T.Invalidated _ -> "invalidated"
             | T.Attached _ -> "attached")
           events
       in
       Alcotest.failf "unexpected structural event order: %s"
         (String.concat "," labels));
  Alcotest.(check bool) "old scope invalid" false
    (T.scope_valid removed.keyed_scope_token);
  run_ok runtime (S.Observer.dispose observer)

let test_keyed_mapi_preflight_failure_preserves_committed_snapshot () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let input = S.Var.create (M.set 1 10 M.empty) in
  let provisional_data = ref None in
  let output =
    K.mapi (S.Var.watch input) ~f:(fun ~key ~data ->
        if key = 2 then provisional_data := Some data;
        data)
  in
  let observer = run_ok runtime (S.Observer.observe output (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  let before =
    match T.entry_identity output 1 with
    | Some identity -> identity
    | None -> Alcotest.fail "missing committed entry"
  in
  T.set_preflight output (fun () -> failwith "preflight");
  run_ok runtime (S.Var.set input (M.set 2 20 M.empty));
  expect_defect "preflight" (run_exit runtime S.stabilize);
  Alcotest.(check bool) "no pending plan" false (T.pending output);
  let after =
    match T.entry_identity output 1 with
    | Some identity -> identity
    | None -> Alcotest.fail "committed entry disappeared"
  in
  Alcotest.(check bool) "scope preserved" true
    (before.keyed_scope_token == after.keyed_scope_token);
  Alcotest.(check bool) "scope remains valid" true
    (T.scope_valid before.keyed_scope_token);
  Alcotest.(check (list (pair int int))) "output preserved" [ (1, 10) ]
    (run_ok runtime (S.Observer.read observer) |> M.to_list);
  T.set_preflight output (fun () -> ());
  run_ok runtime S.stabilize;
  Alcotest.(check (list (pair int int))) "retry commits" [ (2, 20) ]
    (run_ok runtime (S.Observer.read observer) |> M.to_list);
  (match !provisional_data with
   | None -> Alcotest.fail "builder did not run"
   | Some _ -> ());
  run_ok runtime (S.Observer.dispose observer)

exception Injected

let test_keyed_mapi_atomic_fault_rolls_back_topology () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let input = S.Var.create (M.set 1 10 M.empty) in
  let output = K.mapi (S.Var.watch input) ~f:(fun ~key:_ ~data -> data) in
  let observer = run_ok runtime (S.Observer.observe output (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  let before =
    match T.entry_identity output 1 with
    | Some identity -> identity
    | None -> Alcotest.fail "missing committed entry"
  in
  T.set_atomic_fault
    (Some
       {
         Eta_signal_atomic_pass.slot =
           Eta_signal_atomic_pass.After_prospective_validation;
         exn = Injected;
       });
  run_ok runtime (S.Var.set input (M.set 2 20 M.empty));
  expect_defect "atomic fault" (run_exit runtime S.stabilize);
  T.set_atomic_fault None;
  Alcotest.(check bool) "rollback clears pending plan" false (T.pending output);
  let after =
    match T.entry_identity output 1 with
    | Some identity -> identity
    | None -> Alcotest.fail "committed entry disappeared"
  in
  Alcotest.(check bool) "committed scope token preserved" true
    (before.keyed_scope_token == after.keyed_scope_token);
  Alcotest.(check bool) "committed scope remains valid" true
    (T.scope_valid before.keyed_scope_token);
  Alcotest.(check (list (pair int int))) "rolled-back output preserved"
    [ (1, 10) ] (run_ok runtime (S.Observer.read observer) |> M.to_list);
  run_ok runtime S.stabilize;
  Alcotest.(check (list (pair int int))) "retry commits after fault is cleared"
    [ (2, 20) ] (run_ok runtime (S.Observer.read observer) |> M.to_list);
  run_ok runtime (S.Observer.dispose observer)

let test_keyed_removal_discards_nested_bind_switch_to_top_scope () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let left_source = S.Var.create 1 in
  let right_source = S.Var.create 100 in
  let switch_source = S.Var.create false in
  let input = S.Var.create (M.set 1 10 M.empty) in
  let left = S.Var.watch left_source in
  let right = S.Var.watch right_source in
  let nested_bind = ref None in
  let output =
    K.mapi (S.Var.watch input) ~f:(fun ~key:_ ~data:_ ->
        let branch =
          S.bind (S.Var.watch switch_source) (fun use_right ->
              if use_right then right else left)
        in
        nested_bind := Some branch;
        S.map Fun.id branch)
  in
  let observer = run_ok runtime (S.Observer.observe output (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  let branch =
    match !nested_bind with
    | Some branch -> branch
    | None -> Alcotest.fail "missing nested bind"
  in
  let branch_token = T.signal_token branch in
  Alcotest.(check bool) "nested bind starts valid" true
    (T.signal_valid_token branch_token);
  Alcotest.(check int) "left dependent count before removal" 1
    (T.dependent_edge_count_token (T.signal_token left));
  Alcotest.(check bool) "left owns committed branch edge" true
    (T.has_dependent_edge_token ~child:(T.signal_token left) ~parent:branch);
  Alcotest.(check bool) "right has no branch edge" false
    (T.has_dependent_edge_token ~child:(T.signal_token right) ~parent:branch);
  T.reset_counters ();
  run_ok runtime (S.Var.set switch_source true);
  run_ok runtime (S.Var.set input M.empty);
  run_ok runtime S.stabilize;
  Alcotest.(check (list (pair int int))) "keyed output removed" []
    (run_ok runtime (S.Observer.read observer) |> M.to_list);
  Alcotest.(check bool) "nested bind invalidated" false
    (T.signal_valid_token branch_token);
  Alcotest.(check int) "nested bind has no demand" 0
    (T.signal_demand_token branch_token);
  Alcotest.(check bool) "left edge removed" false
    (T.has_dependent_edge_token ~child:(T.signal_token left) ~parent:branch);
  Alcotest.(check bool) "discarded switch never attached right" false
    (T.has_dependent_edge_token ~child:(T.signal_token right) ~parent:branch);
  Alcotest.(check int) "left dependents empty" 0
    (T.dependent_edge_count_token (T.signal_token left));
  Alcotest.(check int) "right dependents empty" 0
    (T.dependent_edge_count_token (T.signal_token right));
  let topology = T.topology_counter_snapshot () in
  Alcotest.(check int) "discarded switch inserts no dynamic edge" 0
    topology.Eta_signal_topology.dynamic_inserts;
  Alcotest.(check int) "removal detaches exactly four committed edges" 4
    topology.Eta_signal_topology.indexed_removals;
  run_ok runtime (S.Observer.dispose observer)

let test_keyed_removal_invalidates_nested_bind_provisional_scope () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let switch_source = S.Var.create false in
  let input = S.Var.create (M.set 1 10 M.empty) in
  let left = S.map (fun use -> if use then 1 else 0) (S.Var.watch switch_source)
  in
  let right = S.map (fun use -> if use then 3 else 2) (S.Var.watch switch_source)
  in
  let nested_bind = ref None in
  let provisional_branch = ref None in
  let output =
    K.mapi (S.Var.watch input) ~f:(fun ~key:_ ~data:_ ->
        let branch =
          S.bind (S.Var.watch switch_source) (fun use_right ->
              if use_right then
                let provisional = S.map (fun value -> value + 1) right in
                provisional_branch := Some provisional;
                provisional
              else left)
        in
        nested_bind := Some branch;
        branch)
  in
  let observer = run_ok runtime (S.Observer.observe output (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  T.reset_counters ();
  run_ok runtime (S.Var.set switch_source true);
  run_ok runtime (S.Var.set input M.empty);
  run_ok runtime S.stabilize;
  let branch = Option.get !nested_bind in
  let provisional =
    match !provisional_branch with
    | Some provisional -> provisional
    | None -> Alcotest.fail "missing provisional branch"
  in
  Alcotest.(check (list (pair int int))) "keyed output removed" []
    (run_ok runtime (S.Observer.read observer) |> M.to_list);
  Alcotest.(check bool) "nested bind invalidated" false
    (T.signal_valid_token (T.signal_token branch));
  Alcotest.(check bool) "provisional branch invalidated" false
    (T.signal_valid_token (T.signal_token provisional));
  Alcotest.(check int) "provisional branch has no demand" 0
    (T.signal_demand_token (T.signal_token provisional));
  Alcotest.(check bool) "provisional branch has no committed edge" false
    (T.has_dependent_edge_token ~child:(T.signal_token right)
       ~parent:provisional);
  Alcotest.(check int) "right dependents empty after rollback" 0
    (T.dependent_edge_count_token (T.signal_token right));
  let topology = T.topology_counter_snapshot () in
  Alcotest.(check int) "discarded provisional switch inserts no dynamic edge" 0
    topology.Eta_signal_topology.dynamic_inserts;
  run_ok runtime (S.Observer.dispose observer)

let test_keyed_removal_clears_nested_bind_pending_state () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let outer_source = S.Var.create false in
  let inner_source = S.Var.create false in
  let input = S.Var.create (M.set 1 10 M.empty) in
  let left =
    S.map (fun use -> if use then 1 else 0) (S.Var.watch outer_source)
  in
  let right =
    S.map (fun use -> if use then 3 else 2) (S.Var.watch inner_source)
  in
  let outer_bind = ref None in
  let inner_bind = ref None in
  let output =
    K.mapi (S.Var.watch input) ~f:(fun ~key:_ ~data:_ ->
        let outer =
          S.bind (S.Var.watch outer_source) (fun use_inner ->
              if use_inner then
                let inner =
                  S.bind (S.Var.watch inner_source) (fun use_right ->
                      if use_right then right else left)
                in
                inner_bind := Some inner;
                inner
              else left)
        in
        outer_bind := Some outer;
        outer)
  in
  let observer = run_ok runtime (S.Observer.observe output (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  let outer = Option.get !outer_bind in
  let outer_token = T.signal_token outer in
  Alcotest.(check bool) "outer bind starts valid" true
    (T.signal_valid_token outer_token);
  Alcotest.(check int) "right starts without dependents" 0
    (T.dependent_edge_count_token (T.signal_token right));
  T.reset_counters ();
  run_ok runtime (S.Var.set outer_source true);
  run_ok runtime (S.Var.set inner_source true);
  run_ok runtime (S.Var.set input M.empty);
  run_ok runtime S.stabilize;
  let inner =
    match !inner_bind with
    | Some inner -> inner
    | None -> Alcotest.fail "missing provisional nested bind"
  in
  let inner_token = T.signal_token inner in
  Alcotest.(check (list (pair int int))) "keyed output removed" []
    (run_ok runtime (S.Observer.read observer) |> M.to_list);
  Alcotest.(check bool) "outer bind invalidated" false
    (T.signal_valid_token outer_token);
  Alcotest.(check bool) "provisional nested bind invalidated" false
    (T.signal_valid_token inner_token);
  Alcotest.(check bool) "outer has no demand" false
    (T.signal_demand_token (T.signal_token outer) > 0);
  Alcotest.(check bool) "inner has no demand" false
    (T.signal_demand_token (T.signal_token inner) > 0);
  Alcotest.(check bool) "inner never attached to right" false
    (T.has_dependent_edge_token ~child:(T.signal_token right) ~parent:inner);
  Alcotest.(check int) "right dependents stay empty" 0
    (T.dependent_edge_count_token (T.signal_token right));
  Alcotest.(check int) "left dependents stay empty" 0
    (T.dependent_edge_count_token (T.signal_token left));
  let topology = T.topology_counter_snapshot () in
  Alcotest.(check int) "retired nested switches insert no dynamic edge" 0
    topology.Eta_signal_topology.dynamic_inserts;
  Alcotest.(check bool) "keyed plan cleared" false (T.pending output);
  run_ok runtime (S.Observer.dispose observer)

let () =
  Alcotest.run "eta_signal_map_keyed_private"
    [
      ( "keyed",
        [
          Alcotest.test_case "keyed_mapi_commit_removes_before_additions" `Quick
            test_keyed_mapi_commit_removes_before_additions;
          Alcotest.test_case
            "keyed_mapi_preflight_failure_preserves_committed_snapshot" `Quick
            test_keyed_mapi_preflight_failure_preserves_committed_snapshot;
          Alcotest.test_case "keyed_mapi_atomic_fault_rolls_back_topology"
            `Quick test_keyed_mapi_atomic_fault_rolls_back_topology;
          Alcotest.test_case
            "keyed_removal_discards_nested_bind_switch_to_top_scope" `Quick
            test_keyed_removal_discards_nested_bind_switch_to_top_scope;
          Alcotest.test_case
            "keyed_removal_invalidates_nested_bind_provisional_scope" `Quick
            test_keyed_removal_invalidates_nested_bind_provisional_scope;
          Alcotest.test_case
            "keyed_removal_clears_nested_bind_pending_state" `Quick
            test_keyed_removal_clears_nested_bind_pending_state;
        ] );
    ]
