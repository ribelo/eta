module E = Eta.Effect

type box = {
  id : int;
  mutable value : int;
}

type sample = {
  generated_key : int;
  generated_key_count : int;
  generated_command_count : int;
  generated_transition_count : int;
}

let box id value = { id; value }

let property_names =
  [|
    "keyed_mapi_addition_builds_one_incarnation";
    "keyed_mapi_builder_runs_for_additions_only";
    "keyed_mapi_retained_key_preserves_incarnation";
    "keyed_mapi_retained_child_preserves_local_state";
    "keyed_mapi_update_publishes_through_existing_source";
    "keyed_mapi_child_reads_accepted_data_same_stabilization";
    "keyed_mapi_continuous_key_preserves_representative";
    "keyed_mapi_removal_invalidates_incarnation";
    "keyed_mapi_reentry_creates_fresh_incarnation";
    "keyed_mapi_final_equal_data_preserves_child";
    "keyed_mapi_final_unequal_data_updates_child";
    "keyed_mapi_final_absence_removes_child";
    "keyed_mapi_same_child_description_isolated_across_keys";
    "keyed_mapi_reused_child_description_shares_within_key_scope";
    "keyed_mapi_data_cutoff_runs_for_retained_physical_changes_only";
    "keyed_mapi_default_data_cutoff_uses_physical_identity";
    "keyed_mapi_data_cutoff_receives_published_then_candidate";
    "keyed_mapi_suppressed_data_keeps_published_value";
    "keyed_mapi_nontransitive_data_cutoff_uses_published_baseline";
    "keyed_mapi_data_cutoff_defect_rolls_back_and_retries";
    "keyed_mapi_same_object_mutation_is_unobservable";
    "keyed_mapi_addition_sets_output_binding";
    "keyed_mapi_removal_removes_output_binding";
    "keyed_mapi_child_only_change_patches_one_binding";
    "keyed_mapi_output_patch_retains_unaffected_ancestry";
    "keyed_mapi_suppressed_update_preserves_output_root";
    "keyed_mapi_child_noop_preserves_output_root";
    "keyed_mapi_rollback_preserves_output_root";
    "keyed_mapi_commit_removes_before_additions";
    "keyed_mapi_builder_defect_rolls_back_provisional_addition";
    "keyed_mapi_preflight_failure_preserves_committed_snapshot";
    "keyed_mapi_rollback_invalidates_provisional_additions";
    "keyed_mapi_rollback_keeps_removal_candidates_live";
    "keyed_mapi_retry_after_rollback_uses_fresh_provisional_identity";
    "keyed_mapi_outer_removal_excludes_nested_plan";
    "keyed_mapi_simultaneous_input_and_child_change_publishes_final_output";
    "keyed_mapi_output_observer_publishes_once_after_commit";
    "keyed_mapi_model_trace_matches_runtime";
  |]

let require name condition detail =
  if not condition then failwith (name ^ ": " ^ detail)

let run_case matrix sample =
  let generated_key = sample.generated_key in
  let name = property_names.(matrix - 1) in
  let key = 1 + (generated_key mod 31) in
  let other = key + 100 in
  let third = key + 200 in
  let module S = Eta_signal_map_api.Make (Eta_signal.No_observer_error) () in
  let module Order = struct
    type t = int
    let compare = Int.compare
  end in
  let module M = Eta_signal_map_api.Map.Make (Order) in
  let module KM = Eta_signal_map_kernel.Make (Order) in
  let module K = S.Keyed (Order) in
  let module T = K.Testing in
  let run_ok = function
    | Ok value -> value
    | Error _ -> failwith (name ^ ": unexpected typed failure")
  in
  let stabilize () = run_ok (S.stabilize ()) in
  let set source value = run_ok (S.Var.set source value) in
  let read observer = run_ok (S.Observer.read observer) in
  let dispose observer = run_ok (S.Observer.dispose observer) in
  let expect_defect f =
    match f () with
    | _ -> false
    | exception _ -> true
  in
  let expect_invalid_scope = function
    | Error `Invalid_scope -> true
    | Error _ | Ok _ -> false
  in
  let raw_data_cutoff f =
    Eta_signal.Cutoff.of_equal (fun published candidate ->
        f ~published ~candidate)
  in
  let data_signals = Hashtbl.create 8 in
  let child_signals = Hashtbl.create 8 in
  let local_sources = Hashtbl.create 8 in
  let builds = ref [] in
  let observer_events = ref 0 in
  let setup ?data_cutoff initial =
    let input = S.Var.create initial in
    let output =
      K.mapi ?data_cutoff (S.Var.watch input) ~f:(fun ~key ~data ->
          builds := key :: !builds;
          let local = S.Var.create 0 in
          Hashtbl.replace data_signals key data;
          Hashtbl.replace local_sources key local;
          let child =
            S.map2 (fun data local -> data.value + local) data
              (S.Var.watch local)
          in
          Hashtbl.replace child_signals key child;
          child)
    in
    let observer =
      run_ok
        (S.Observer.observe output ~on_update:(fun _update ->
             incr observer_events;
             Ok ()))
    in
    stabilize ();
    (input, output, observer)
  in
  let one value = M.set key value M.empty in
  let identity output selected =
    match T.entry_identity output selected with
    | Some identity -> identity
    | None -> failwith (name ^ ": missing identity")
  in
  let output_value observer selected =
    match M.find_opt selected (read observer) with
    | Some value -> value
    | None -> failwith (name ^ ": missing output")
  in
  let same_identity (left : T.entry_identity) (right : T.entry_identity) =
    left.keyed_scope_token == right.keyed_scope_token
    && left.keyed_source_token == right.keyed_source_token
    && left.keyed_data_signal_token == right.keyed_data_signal_token
    && left.keyed_child_signal_token == right.keyed_child_signal_token
  in
  match matrix with
  | 1 | 22 ->
      let input, output, observer = setup M.empty in
      set input (one (box 1 10));
      stabilize ();
      let id = identity output key in
      require name (List.length !builds = 1) "builder count";
      require name id.keyed_edge_attached "missing child edge";
      require name (output_value observer key = 10) "wrong output";
      dispose observer
  | 2 ->
      let initial = M.set other (box 2 20) (one (box 1 10)) in
      let input, _output, observer = setup initial in
      let before = List.length !builds in
      let final = M.set third (box 4 40) (one (box 3 30)) in
      set input final;
      stabilize ();
      require name (List.length !builds = before + 1) "non-addition rebuilt";
      dispose observer
  | 3 | 5 ->
      let input, output, observer = setup (one (box 1 10)) in
      let before = identity output key in
      set input (one (box 2 20));
      stabilize ();
      let after = identity output key in
      require name (same_identity before after) "incarnation changed";
      require name (List.length !builds = 1) "builder reran";
      dispose observer
  | 7 ->
      let module Representative = struct
        type t = { rank : int; label : string }
        let compare left right = Int.compare left.rank right.rank
      end in
      let module RM = Eta_signal_map_api.Map.Make (Representative) in
      let module RK = S.Keyed (Representative) in
      let first = Representative.{ rank = key; label = "first" } in
      let equal_key = Representative.{ rank = key; label = "second" } in
      let input = S.Var.create (RM.set first (box 1 10) RM.empty) in
      let output =
        RK.mapi (S.Var.watch input) ~f:(fun ~key:_ ~data ->
            S.map (fun data -> data.value) data)
      in
      let observer = run_ok (S.Observer.observe output ~on_update:(fun _ -> Ok ())) in
      stabilize ();
      let before =
        match RK.Testing.entry_identity output first with
        | Some identity -> identity
        | None -> failwith (name ^ ": missing representative")
      in
      set input (RM.set equal_key (box 2 20) RM.empty);
      stabilize ();
      let stored : Representative.t = Obj.obj before.keyed_key_token in
      require name (stored == first) "stored representative replaced";
      dispose observer
  | 4 | 6 ->
      let input, _output, observer = setup (one (box 1 10)) in
      set (Hashtbl.find local_sources key) 7;
      set input (one (box 2 20));
      stabilize ();
      require name (output_value observer key = 27) "same-stabilization value";
      require name (List.length !builds = 1) "child rebuilt";
      dispose observer
  | 8 | 23 ->
      let input, output, observer = setup (one (box 1 10)) in
      let before = identity output key in
      set input M.empty;
      stabilize ();
      require name (M.is_empty (read observer)) "binding retained";
      require name (not (T.scope_valid before.keyed_scope_token)) "scope valid";
      dispose observer
  | 9 ->
      let input, output, observer = setup (one (box 1 10)) in
      let before = identity output key in
      set input M.empty;
      stabilize ();
      set input (one (box 2 20));
      stabilize ();
      let after = identity output key in
      require name (not (same_identity before after)) "incarnation reused";
      require name (not (T.scope_valid before.keyed_scope_token)) "old scope revived";
      dispose observer
  | 10 ->
      let stable = one (box 1 10) in
      let input, output, observer = setup stable in
      let before = identity output key in
      set input M.empty;
      set input stable;
      stabilize ();
      require name (same_identity before (identity output key)) "transient rebuild";
      require name (List.length !builds = 1) "transient builder";
      dispose observer
  | 11 ->
      let input, output, observer = setup (one (box 1 10)) in
      let before = identity output key in
      set input M.empty;
      set input (one (box 2 30));
      stabilize ();
      require name (same_identity before (identity output key)) "transient rebuild";
      require name (output_value observer key = 30) "final data not published";
      dispose observer
  | 12 ->
      let input, _output, observer = setup (one (box 1 10)) in
      set input (one (box 2 20));
      set input M.empty;
      stabilize ();
      require name (M.is_empty (read observer)) "final absence ignored";
      require name (List.length !builds = 1) "transient build";
      dispose observer
  | 13 ->
      let initial = M.set other (box 2 20) (one (box 1 10)) in
      let _input, output, observer = setup initial in
      let left = identity output key in
      let right = identity output other in
      require name (left.keyed_scope_token != right.keyed_scope_token) "shared scope";
      require name (left.keyed_data_signal_token != right.keyed_data_signal_token)
        "shared data cell";
      require name (left.keyed_child_signal_token != right.keyed_child_signal_token)
        "shared child cell";
      dispose observer
  | 14 ->
      let input = S.Var.create (one (box 1 10)) in
      let same = ref None in
      let output =
        K.mapi (S.Var.watch input) ~f:(fun ~key:_ ~data ->
            let mapped = S.map (fun data -> data.value) data in
            same := Some (mapped, mapped);
            S.map2 ( + ) mapped mapped)
      in
      let observer = run_ok (S.Observer.observe output ~on_update:(fun _ -> Ok ())) in
      stabilize ();
      (match !same with
       | Some (left, right) -> require name (left == right) "description duplicated"
       | None -> failwith (name ^ ": builder not run"));
      require name (output_value observer key = 20) "wrong shared output";
      dispose observer
  | 15 ->
      let calls = ref [] in
      let cutoff ~published ~candidate =
        calls := (published, candidate) :: !calls;
        false
      in
      let unchanged = box 3 30 in
      let initial =
        M.set third unchanged
          (M.set other (box 2 20) (one (box 1 10)))
      in
      let input, _output, observer =
        setup ~data_cutoff:(raw_data_cutoff cutoff) initial
      in
      let final =
        M.set (third + 1) (box 5 50)
          (M.set third unchanged (one (box 4 40)))
      in
      set input final;
      stabilize ();
      require name (List.length !calls = 1) "cutoff called outside retained change";
      dispose observer
  | 16 ->
      let original = box 1 10 in
      let input = S.Var.create (one original) in
      let output =
        K.mapi (S.Var.watch input) ~f:(fun ~key:_ ~data ->
            S.map (fun data -> data.id) data)
      in
      let observer = run_ok (S.Observer.observe output ~on_update:(fun _ -> Ok ())) in
      stabilize ();
      set input (one original);
      stabilize ();
      require name (output_value observer key = 1) "shared changed";
      let distinct = box 2 10 in
      set input (one distinct);
      stabilize ();
      require name (output_value observer key = 2) "distinct not published";
      dispose observer
  | 17 ->
      let published = box 1 10 in
      let candidate = box 2 20 in
      let calls = ref [] in
      let input, _output, observer =
        setup
          ~data_cutoff:
            (raw_data_cutoff (fun ~published ~candidate ->
               calls := (published, candidate) :: !calls;
               false))
          (one published)
      in
      set input (one candidate);
      stabilize ();
      require name (!calls = [ (published, candidate) ]) "argument direction";
      dispose observer
  | 18 | 26 ->
      let published = box 1 10 in
      let candidate = box 2 20 in
      let input, _output, observer =
        setup ~data_cutoff:Eta_signal.Cutoff.always (one published)
      in
      let root = read observer in
      set input (one candidate);
      stabilize ();
      require name (output_value observer key = 10) "suppressed data published";
      require name (read observer == root) "suppression changed root";
      dispose observer
  | 19 ->
      let a = box 1 1 and b = box 2 2 and c = box 3 3 in
      let calls = ref [] in
      let cutoff ~published ~candidate =
        calls := !calls @ [ (published, candidate) ];
        published == a && candidate == b
      in
      let input, _output, observer =
        setup ~data_cutoff:(raw_data_cutoff cutoff) (one a)
      in
      set input (one b);
      stabilize ();
      set input (one c);
      stabilize ();
      require name (!calls = [ (a, b); (a, c) ]) "raw baseline used";
      require name (output_value observer key = 3) "C not published";
      dispose observer
  | 20 ->
      let old = box 1 10 and next = box 2 20 in
      let calls = ref 0 and fail = ref true in
      let input, _output, observer =
        setup
          ~data_cutoff:
            (raw_data_cutoff (fun ~published:_ ~candidate:_ ->
               incr calls;
               if !fail then failwith "cutoff";
               false))
          (one old)
      in
      set input (one next);
      require name (expect_defect (fun () -> ignore (S.stabilize ()))) "missing defect";
      require name (output_value observer key = 10) "failure published";
      fail := false;
      stabilize ();
      require name (!calls = 2) "cutoff not retried";
      require name (output_value observer key = 20) "retry not published";
      dispose observer
  | 21 ->
      let shared = box 1 10 in
      let calls = ref 0 in
      let input, _output, observer =
        setup
          ~data_cutoff:
            (raw_data_cutoff (fun ~published:_ ~candidate:_ ->
               incr calls;
               false))
          (one shared)
      in
      shared.value <- 20;
      set input (one shared);
      stabilize ();
      require name (!calls = 0) "same object reached cutoff";
      require name (output_value observer key = 10) "mutation became observable";
      dispose observer
  | 24 | 36 ->
      let input, _output, observer = setup (one (box 1 10)) in
      let local = Hashtbl.find local_sources key in
      set local 5;
      if matrix = 36 then set input (one (box 2 20));
      stabilize ();
      let expected = if matrix = 36 then 25 else 15 in
      require name (output_value observer key = expected) "wrong patched output";
      dispose observer
  | 25 ->
      let initial =
        List.init 31 (fun offset -> (key + offset, box offset offset))
        |> List.fold_left (fun map (key, value) -> M.set key value map) M.empty
      in
      let _input, _output, observer = setup initial in
      let before = read observer in
      set (Hashtbl.find local_sources (key + 30)) 1;
      stabilize ();
      let after = read observer in
      require name (before != after) "output root unchanged";
      require name (KM.shared_node_count before after > 0) "ancestry rebuilt";
      dispose observer
  | 27 ->
      let input = S.Var.create (one (box 1 10)) in
      let local = ref None in
      let output =
        K.mapi (S.Var.watch input) ~f:(fun ~key:_ ~data ->
            let source = S.Var.create 0 in
            local := Some source;
            S.map2 ~cutoff:(Eta_signal.Cutoff.of_equal Int.equal)
              (fun data local -> data.value + (local mod 1))
              data (S.Var.watch source))
      in
      let observer = run_ok (S.Observer.observe output ~on_update:(fun _ -> Ok ())) in
      stabilize ();
      let root = read observer in
      set (Option.get !local) 7;
      stabilize ();
      require name (read observer == root) "child noop changed root";
      dispose observer
  | 28 ->
      let input, output, observer = setup (one (box 1 10)) in
      let root = read observer in
      let before = identity output key in
      T.set_preflight output (fun () -> failwith "preflight");
      set input (M.set other (box 2 20) M.empty);
      require name (expect_defect (fun () -> ignore (S.stabilize ()))) "missing preflight defect";
      require name (read observer == root) "rollback changed root";
      require name (same_identity before (identity output key)) "committed identity lost";
      require name (T.scope_valid before.keyed_scope_token) "removal candidate invalid";
      require name (not (T.pending output)) "pending plan retained";
      dispose observer
  | 31 ->
      let initial = M.set other (box 2 20) (one (box 1 10)) in
      let input, output, observer = setup initial in
      let root = read observer in
      let kept_before = identity output key in
      let removed_before = identity output other in
      T.set_preflight output (fun () -> failwith "preflight");
      let final = M.set third (box 4 40) (one (box 3 30)) in
      set input final;
      require name (expect_defect (fun () -> ignore (S.stabilize ()))) "missing preflight defect";
      require name (read observer == root) "snapshot root changed";
      require name (same_identity kept_before (identity output key))
        "retained update identity changed";
      require name (same_identity removed_before (identity output other))
        "removal candidate identity changed";
      require name (T.scope_valid removed_before.keyed_scope_token)
        "removal candidate invalidated";
      require name (not (T.pending output)) "pending plan retained";
      dispose observer
  | 29 ->
      let initial = M.set other (box 2 20) (one (box 1 10)) in
      let input, output, observer = setup initial in
      let events = ref [] in
      T.set_event_recorder output (fun event -> events := !events @ [ event ]);
      set input (M.set third (box 3 30) M.empty);
      stabilize ();
      let labels =
        List.map
          (function T.Detached _ -> 0 | T.Invalidated _ -> 1 | T.Attached _ -> 2)
          !events
      in
      require name (labels = [ 0; 1; 0; 1; 2 ])
        "removal/addition barrier";
      dispose observer
  | 30 | 32 | 34 ->
      let input = S.Var.create M.empty in
      let fail = ref true in
      let captured = ref [] in
      let output =
        K.mapi (S.Var.watch input) ~f:(fun ~key:_ ~data ->
            captured := data :: !captured;
            if !fail && (matrix <> 32 || List.length !captured = 2) then
              failwith "builder";
            data)
      in
      let observer = run_ok (S.Observer.observe output ~on_update:(fun _ -> Ok ())) in
      stabilize ();
      set input (M.set other (box 2 20) (one (box 1 10)));
      require name (expect_defect (fun () -> ignore (S.stabilize ()))) "missing builder defect";
      require name (M.is_empty (read observer)) "provisional output published";
      require name (not (T.pending output)) "pending plan retained";
      List.iter
        (fun data ->
          require name
            (expect_invalid_scope
                (S.Observer.observe data ~on_update:(fun _ -> Ok ())))
            "provisional scope remains valid")
        !captured;
      let first_tokens = !captured in
      fail := false;
      stabilize ();
      require name (M.cardinal (read observer) = 2) "retry failed";
      if matrix = 34 then
        require name
          (List.exists
             (fun signal -> List.for_all (fun old -> signal != old) first_tokens)
             !captured)
          "provisional identity reused";
      dispose observer
  | 33 ->
      let initial = one (box 1 10) in
      let input = S.Var.create initial in
      let local = S.Var.create 0 in
      let output =
        K.mapi (S.Var.watch input) ~f:(fun ~key:_ ~data ->
            S.map2 (fun data local -> data.value + local) data
              (S.Var.watch local))
      in
      let fail_downstream = ref false in
      let guarded =
        S.map
          (fun value ->
            if !fail_downstream then failwith "downstream";
            value)
          output
      in
      let observer =
        run_ok (S.Observer.observe guarded ~on_update:(fun _ -> Ok ()))
      in
      stabilize ();
      let before = identity output key in
      let stats_before = (run_ok (S.stats ())).keyed in
      fail_downstream := true;
      set input M.empty;
      require name
        (expect_defect (fun () -> ignore (S.stabilize ())))
        "missing downstream defect";
      let stats_after_failure = (run_ok (S.stats ())).keyed in
      require name
        (stats_after_failure.committed_removal_count
         = stats_before.committed_removal_count)
        "failed removal counted as committed";
      require name
        (stats_after_failure.reconciliation_rollback_count
         = stats_before.reconciliation_rollback_count + 1)
        "failed reconciliation rollback count";
      require name
        (same_identity before (identity output key))
        "removal candidate identity changed";
      require name
        (T.scope_valid before.keyed_scope_token)
        "removal candidate invalidated";
      set input initial;
      fail_downstream := false;
      stabilize ();
      set local 5;
      stabilize ();
      require name (output_value observer key = 15)
        "restored child stopped propagating";
      dispose observer
  | 35 ->
      let choose = S.Var.create true in
      let nested_input = S.Var.create M.empty in
      let nested_output = ref None in
      let owner =
        S.bind (S.Var.watch choose) ~f:(fun active ->
            if active then (
              let nested =
                K.mapi (S.Var.watch nested_input) ~f:(fun ~key:_ ~data -> data)
              in
              nested_output := Some nested;
              nested)
            else S.const M.empty)
      in
      let observer = run_ok (S.Observer.observe owner ~on_update:(fun _ -> Ok ())) in
      stabilize ();
      set nested_input (one (box 1 10));
      set choose false;
      stabilize ();
      require name (M.is_empty (read observer)) "outer removal leaked nested plan";
      (match !nested_output with
       | Some nested -> require name (not (T.pending nested)) "nested plan pending"
       | None -> failwith (name ^ ": nested builder missing"));
      dispose observer
  | 37 ->
      let input, _output, observer = setup (one (box 1 10)) in
      observer_events := 0;
      set input (one (box 2 20));
      stabilize ();
      require name (!observer_events = 1) "observer did not publish once";
      let before = !observer_events in
      stabilize ();
      require name (!observer_events = before) "noop observer event";
      dispose observer
  | 38 ->
      let input, _output, observer = setup M.empty in
      let model = ref M.empty in
      for step = 0 to sample.generated_transition_count - 1 do
        let key_count = sample.generated_key_count in
        let selected = key + (if key_count = 0 then 0 else step mod key_count) in
        if key_count = 0 then (
          model := M.empty;
          set input !model)
        else if (generated_key + step) mod 3 = 0 then (
          model := M.remove selected !model;
          set input !model)
        else (
          let value = box (step + 1) (generated_key + step) in
          model := M.set selected value !model;
          set input !model);
        if
          (step + 1) mod sample.generated_command_count = 0
          || step = sample.generated_transition_count - 1
        then (
          stabilize ();
          let expected = M.map (fun data -> data.value) !model in
          require name (M.equal Int.equal expected (read observer)) "trace mismatch")
      done;
      stabilize ();
      let expected = M.map (fun data -> data.value) !model in
      require name (M.equal Int.equal expected (read observer)) "final trace mismatch";
      dispose observer
  | _ -> invalid_arg "keyed property matrix"

let sample_arbitrary =
  let open QCheck.Gen in
  QCheck.make
    ~print:(fun sample ->
      Printf.sprintf "{key=%d; keys=%d; commands=%d; transitions=%d}"
        sample.generated_key sample.generated_key_count
        sample.generated_command_count sample.generated_transition_count)
    (map4
       (fun generated_key generated_key_count generated_command_count
            generated_transition_count ->
         {
           generated_key;
           generated_key_count;
           generated_command_count;
           generated_transition_count;
         })
       (0 -- 10_000) (0 -- 32) (1 -- 16) (1 -- 128))

let properties =
  Array.to_list property_names
  |> List.mapi (fun index name ->
         QCheck.Test.make ~count:1000 ~name sample_arbitrary
           (fun sample ->
             run_case (index + 1) sample;
             true))

let () =
  properties
  |> List.iteri (fun index property ->
         let seed =
           if index = 37 then
             Random.State.make [| 0xE22; 0x4B4559; 0x535452 |]
           else Random.State.make [| 0xE22; 0x4B4D; index + 1 |]
         in
         let code =
           QCheck_base_runner.run_tests ~colors:false ~verbose:true ~rand:seed
             [ property ]
         in
         if code <> 0 then exit code)
