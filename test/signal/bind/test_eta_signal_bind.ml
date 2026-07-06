module Bind = Eta_signal_bind
module T = Eta_signal_transaction

let capability = "bind-capability"

let check_cap cap =
  Alcotest.(check string) "capability" capability cap

let test_empty_snapshot () =
  let snapshot = Bind.empty in
  Alcotest.(check (option string)) "inner" None (Bind.inner snapshot);
  Alcotest.(check (option int)) "scope" None (Bind.inner_scope snapshot)

let test_switch_snapshot () =
  let snapshot = Bind.switch ~source_value:1 ~inner:"inner" ~scope:2 in
  Alcotest.(check (option string)) "inner" (Some "inner")
    (Bind.inner snapshot);
  Alcotest.(check (option int)) "scope" (Some 2) (Bind.inner_scope snapshot)

let test_stage_transaction_switch_remembers_once () =
  let effects = ref [] in
  let staged = T.create_staged Bind.empty in
  let tx : (T.pure, unit) T.t = T.begin_pure () in
  let remember () = effects := !effects @ [ "remember" ] in
  Bind.stage_transaction_switch tx staged ~remember ~source_value:1
    ~inner:"inner" ~scope:2;
  Alcotest.(check (list string)) "remembered first stage" [ "remember" ]
    !effects;
  Alcotest.(check bool) "staged" true (T.staged tx staged);
  let first = T.read tx staged in
  Alcotest.(check (option string)) "inner" (Some "inner") (Bind.inner first);
  Alcotest.(check (option int)) "scope" (Some 2) (Bind.inner_scope first);
  Bind.stage_transaction_switch tx staged ~remember ~source_value:2
    ~inner:"next" ~scope:3;
  Alcotest.(check (list string)) "remembered once" [ "remember" ] !effects;
  let updated = T.read tx staged in
  Alcotest.(check (option string)) "updated inner" (Some "next")
    (Bind.inner updated);
  Alcotest.(check (option int)) "updated scope" (Some 3)
    (Bind.inner_scope updated)

let test_staged_switch_commit_runs_graph_effects_in_bind_order () =
  let current = Bind.switch ~source_value:0 ~inner:"old" ~scope:1 in
  let staged = Bind.switch ~source_value:1 ~inner:"new" ~scope:2 in
  let effects = ref [] in
  let record effect = effects := !effects @ [ effect ] in
  let switch = Bind.staged_switch ~owner:(Some "owner") ~current
      ~staged:(Some staged)
  in
  let lifecycle =
    Bind.staged_switch_lifecycle
      ~detach_old_inner:(fun owner inner ->
        record ("detach:" ^ owner ^ ":" ^ inner))
      ~invalidate_scope:(fun scope ->
        record ("invalidate:" ^ string_of_int scope);
        [ "cleanup:" ^ string_of_int scope ])
      ~attach_new_inner:(fun owner inner ->
        record ("attach:" ^ owner ^ ":" ^ inner))
  in
  match
    Bind.commit_staged_switch switch lifecycle
  with
  | Ok hooks ->
      Alcotest.(check (list string))
        "effect order"
        [
          "detach:owner:old";
          "invalidate:1";
          "attach:owner:new";
        ]
        !effects;
      Alcotest.(check (list string)) "hooks" [ "cleanup:1" ] hooks
  | Error `Invalid_scope -> Alcotest.fail "expected commit plan"

let test_staged_switch_no_staged_snapshot_is_noop () =
  let current = Bind.switch ~source_value:0 ~inner:"old" ~scope:1 in
  let effects = ref [] in
  let switch = Bind.staged_switch ~owner:None ~current ~staged:None in
  let lifecycle =
    Bind.staged_switch_lifecycle
      ~detach_old_inner:(fun _ _ -> effects := "detach" :: !effects)
      ~invalidate_scope:(fun _ ->
        effects := "invalidate" :: !effects;
        [])
      ~attach_new_inner:(fun _ _ -> effects := "attach" :: !effects)
  in
  (match
     Bind.commit_staged_switch switch lifecycle
   with
  | Ok hooks -> Alcotest.(check (list string)) "commit hooks" [] hooks
  | Error `Invalid_scope -> Alcotest.fail "expected noop commit");
  (match
     Bind.preflight_staged_switch switch ~collect_old_scope:(fun _ _ ->
         effects := "preflight" :: !effects)
   with
  | Ok () -> ()
  | Error `Invalid_scope -> Alcotest.fail "expected noop preflight");
  (match
     Bind.rollback_staged_switch ~staged:None lifecycle
   with
  | Ok hooks -> Alcotest.(check (list string)) "rollback hooks" [] hooks
  | Error `Invalid_scope -> Alcotest.fail "expected noop rollback");
  Alcotest.(check (list string)) "effects" [] !effects

let test_staged_switch_rejects_missing_owner () =
  let current = Bind.switch ~source_value:0 ~inner:"old" ~scope:1 in
  let staged = Bind.switch ~source_value:1 ~inner:"new" ~scope:2 in
  let switch =
    Bind.staged_switch ~owner:None ~current ~staged:(Some staged)
  in
  let lifecycle =
    Bind.staged_switch_lifecycle ~detach_old_inner:(fun _ _ -> ())
      ~invalidate_scope:(fun _ -> []) ~attach_new_inner:(fun _ _ -> ())
  in
  Alcotest.(check bool) "commit rejected" true
    (Result.is_error
       (Bind.commit_staged_switch switch lifecycle));
  Alcotest.(check bool) "preflight rejected" true
    (Result.is_error
       (Bind.preflight_staged_switch switch ~collect_old_scope:(fun _ _ ->
            ())))

let test_staged_switch_preflight_uses_owner_for_old_scope () =
  let current = Bind.switch ~source_value:0 ~inner:"old" ~scope:1 in
  let staged = Bind.switch ~source_value:1 ~inner:"new" ~scope:2 in
  let collected = ref [] in
  let switch = Bind.staged_switch ~owner:(Some "owner") ~current
      ~staged:(Some staged)
  in
  match
    Bind.preflight_staged_switch switch ~collect_old_scope:(fun owner scope ->
        collected := (owner, scope) :: !collected)
  with
  | Ok () ->
      Alcotest.(check (list (pair string int)))
        "collected" [ ("owner", 1) ] !collected
  | Error `Invalid_scope -> Alcotest.fail "expected preflight"

let packed_staged_switch = Bind.pack_staged_switch

let test_collect_staged_switch_invalidations_collects_old_scopes () =
  let first =
    Bind.staged_switch ~owner:(Some "first")
      ~current:(Bind.switch ~source_value:0 ~inner:"old-first" ~scope:1)
      ~staged:
        (Some
           (Bind.switch ~source_value:1 ~inner:"new-first" ~scope:10))
  in
  let unstaged =
    Bind.staged_switch ~owner:(Some "unstaged")
      ~current:(Bind.switch ~source_value:0 ~inner:"old-unstaged" ~scope:2)
      ~staged:None
  in
  let second =
    Bind.staged_switch ~owner:(Some "second")
      ~current:(Bind.switch ~source_value:0 ~inner:"old-second" ~scope:3)
      ~staged:
        (Some
           (Bind.switch ~source_value:1 ~inner:"new-second" ~scope:30))
  in
  match
    Bind.collect_staged_switch_invalidations ~init:[]
      ~switches:[ first; unstaged; second ] ~staged_switch:packed_staged_switch
      ~collect_old_scope:(fun collected ~owner scope ->
        collected @ [ (owner, scope) ])
  with
  | Ok collected ->
      Alcotest.(check (list (pair string int)))
        "collected old scopes" [ ("first", 1); ("second", 3) ] collected
  | Error `Invalid_scope -> Alcotest.fail "expected collection"

let test_collect_staged_switch_invalidations_rejects_missing_owner () =
  let missing_owner =
    Bind.staged_switch ~owner:None
      ~current:(Bind.switch ~source_value:0 ~inner:"old" ~scope:1)
      ~staged:(Some (Bind.switch ~source_value:1 ~inner:"new" ~scope:2))
  in
  Alcotest.(check bool)
    "missing owner rejected" true
    (Result.is_error
       (Bind.collect_staged_switch_invalidations ~init:[]
          ~switches:[ missing_owner ] ~staged_switch:packed_staged_switch
          ~collect_old_scope:(fun collected ~owner scope ->
            collected @ [ (owner, scope) ])))

let test_staged_switch_rejects_incomplete_staged_snapshot () =
  let current = Bind.switch ~source_value:0 ~inner:"old" ~scope:1 in
  let switch =
    Bind.staged_switch ~owner:(Some "owner") ~current
      ~staged:(Some Bind.empty)
  in
  let lifecycle =
    Bind.staged_switch_lifecycle ~detach_old_inner:(fun _ _ -> ())
      ~invalidate_scope:(fun _ -> []) ~attach_new_inner:(fun _ _ -> ())
  in
  Alcotest.(check bool) "commit rejected" true
    (Result.is_error
       (Bind.commit_staged_switch switch lifecycle));
  Alcotest.(check bool) "rollback rejected" true
    (Result.is_error
       (Bind.rollback_staged_switch ~staged:(Some Bind.empty) lifecycle));
  Alcotest.(check bool) "preflight rejected" true
    (Result.is_error
       (Bind.preflight_staged_switch switch ~collect_old_scope:(fun _ _ ->
            ())))

let test_dependencies_include_source_and_current_inner () =
  Alcotest.(check (list int))
    "source only" [ 1 ]
    (Bind.dependencies ~source:1 ~inner:None);
  Alcotest.(check (list int))
    "source then inner" [ 1; 2 ]
    (Bind.dependencies ~source:1 ~inner:(Some 2))

let dynamic_common_callbacks ?(inner_changed = false)
    ?(dependencies_changed = false) events =
  let with_scope scope f =
    events := !events @ [ "scope:" ^ string_of_int scope ];
    f ()
  in
  let validate_inner scope inner =
    events :=
      !events
      @ [ "validate:" ^ string_of_int scope ^ ":" ^ string_of_int inner ];
    Ok ()
  in
  let compute_inner inner =
    events := !events @ [ "compute:" ^ string_of_int inner ];
    (inner * 10, inner_changed)
  in
  let dependencies_changed dependencies =
    events :=
      !events
      @ [
          "dependencies:"
          ^ String.concat ","
              (List.map string_of_int dependencies);
        ];
    dependencies_changed
  in
  (with_scope, validate_inner, compute_inner, dependencies_changed)

let dynamic_contexts ?(inner_changed = false) ?(dependencies_changed = false)
    ?(dirty = false) ?(initialized = true) ?(current = Some (-1))
    ?(source_value = 3) ?(source_changed = false) ?selector_override
    ?validate_inner_override ?compute_inner_override
    ?on_switch_failure_override events =
  let with_scope, validate_inner, default_compute_inner, dependencies_changed =
    dynamic_common_callbacks ~inner_changed ~dependencies_changed events
  in
  let scope_plan =
    Bind.dynamic_scope_plan
      ~new_scope:(fun cap ->
        check_cap cap;
        events := !events @ [ "new_scope" ];
        7)
      ~with_scope:(fun cap scope f ->
        check_cap cap;
        with_scope scope f)
      ~on_switch_failure:
        (match on_switch_failure_override with
        | Some on_switch_failure -> on_switch_failure
        | None ->
            fun cap _scope ->
              check_cap cap;
              Alcotest.fail "unexpected cleanup")
  in
  let inner_plan =
    Bind.dynamic_inner_plan
      ~selector:
        (match selector_override with
        | Some selector -> selector
        | None ->
            fun source ->
              events := !events @ [ "select:" ^ string_of_int source ];
              source + 1)
      ~validate_inner:
        (match validate_inner_override with
        | Some validate_inner -> validate_inner
        | None ->
            fun cap scope inner ->
              check_cap cap;
              validate_inner scope inner)
      ~compute_inner:
        (match compute_inner_override with
        | Some compute_inner -> compute_inner
        | None ->
            fun cap inner ->
              check_cap cap;
              default_compute_inner inner)
  in
  let reuse =
    Bind.dynamic_reuse_plan ~dirty
      ~dependencies_changed:(fun cap dependencies ->
        check_cap cap;
        dependencies_changed dependencies)
  in
  let source =
    Bind.dynamic_source_plan ~equal:Int.equal
      ~compute_source:(fun cap ->
        check_cap cap;
        events :=
          !events @ [ "compute_source:" ^ string_of_int source_value ];
        (source_value, source_changed))
      ~dependencies:
        (Bind.dynamic_dependencies ~source:100
           ~pack_inner:(fun inner -> inner + 1000))
  in
  let value =
    Bind.dynamic_value_context
      ~state:(fun () -> Bind.dynamic_value_state ~initialized ~current)
      ~cached_value:(fun () ->
        events := !events @ [ "cached" ];
        match current with
        | Some value -> value
        | None -> invalid_arg "missing current")
      ~value_equal:Int.equal
      ~bump_recompute:(fun () -> events := !events @ [ "bump" ])
  in
  let staging =
    Bind.dynamic_staging_context
      ~stage_switch:(fun ~source_value ~inner ~scope ->
        events :=
          !events
          @ [
              "switch:"
              ^ String.concat ":"
                  (List.map string_of_int [ source_value; inner; scope ]);
            ])
      ~stage_dependencies:(fun dependencies ->
        events :=
          !events
          @ [
              "stage_dependencies:"
              ^ String.concat "," (List.map string_of_int dependencies);
            ])
      ~stage_value:(fun value ->
        events := !events @ [ "stage_value:" ^ string_of_int value ])
  in
  Bind.dynamic_context ~source ~scope:scope_plan ~inner:inner_plan ~reuse
    ~value ~staging

let run_dynamic context snapshot =
  match
    Bind.run_dynamic context capability snapshot
  with
  | Ok result -> result
  | Error `Invalid_scope -> Alcotest.fail "expected valid dynamic bind"

let test_run_dynamic_switch_owns_eval_and_apply_order () =
  let events = ref [] in
  let context = dynamic_contexts events in
  Alcotest.(check (pair int bool)) "result" (40, true)
    (run_dynamic context Bind.empty);
  Alcotest.(check (list string))
    "events"
    [
      "compute_source:3";
      "new_scope";
      "scope:7";
      "select:3";
      "validate:7:4";
      "compute:4";
      "bump";
      "switch:3:4:7";
      "stage_dependencies:100,1004";
      "stage_value:40";
    ]
    !events

let test_run_dynamic_reuse_paths () =
  let events = ref [] in
  let snapshot = Bind.switch ~source_value:3 ~inner:4 ~scope:7 in
  let cached = dynamic_contexts events in
  let recomputed = dynamic_contexts ~dependencies_changed:true events in
  let uninitialized =
    dynamic_contexts ~initialized:false ~current:None events
  in
  let missing_current = dynamic_contexts ~current:None events in
  Alcotest.(check (pair int bool))
    "cached result" (-1, false)
    (run_dynamic cached snapshot);
  Alcotest.(check (pair int bool))
    "recomputed result" (40, true)
    (run_dynamic recomputed snapshot);
  Alcotest.(check (pair int bool))
    "uninitialized result" (40, true)
    (run_dynamic uninitialized snapshot);
  Alcotest.check_raises "cached missing current"
    (Invalid_argument "missing current")
    (fun () ->
      ignore (run_dynamic missing_current snapshot));
  Alcotest.(check (list string))
    "events"
    [
      "compute_source:3";
      "compute:4";
      "dependencies:100,1004";
      "cached";
      "compute_source:3";
      "compute:4";
      "dependencies:100,1004";
      "bump";
      "stage_dependencies:100,1004";
      "stage_value:40";
      "compute_source:3";
      "compute:4";
      "dependencies:100,1004";
      "bump";
      "stage_dependencies:100,1004";
      "stage_value:40";
      "compute_source:3";
      "compute:4";
      "dependencies:100,1004";
      "cached";
    ]
    !events

let test_run_dynamic_dirty_reuse_recomputes_with_cutoff () =
  let events = ref [] in
  let snapshot = Bind.switch ~source_value:3 ~inner:4 ~scope:7 in
  let context = dynamic_contexts ~dirty:true ~current:(Some 40) events in
  Alcotest.(check (pair int bool)) "result" (40, false)
    (run_dynamic context snapshot);
  Alcotest.(check (list string))
    "events"
    [
      "compute_source:3";
      "compute:4";
      "bump";
      "stage_dependencies:100,1004";
      "cached";
    ]
    !events

type dynamic_switch_failure =
  | Selector_defect
  | Validation_error
  | Validation_defect
  | Compute_defect

exception Dynamic_switch_failure of string

let dynamic_switch_failure_name = function
  | Selector_defect -> "selector defect"
  | Validation_error -> "validation error"
  | Validation_defect -> "validation defect"
  | Compute_defect -> "compute defect"

let dynamic_switch_failure_defect = function
  | Selector_defect -> "selector"
  | Validation_defect -> "validation"
  | Compute_defect -> "compute"
  | Validation_error -> invalid_arg "validation error has no defect"

let dynamic_switch_failure_cases =
  [
    Selector_defect;
    Validation_error;
    Validation_defect;
    Compute_defect;
  ]

let expected_dynamic_switch_failure_events = function
  | Selector_defect ->
      [ "compute_source:3"; "new_scope"; "scope:7"; "select:3"; "cleanup:7" ]
  | Validation_error | Validation_defect ->
      [
        "compute_source:3";
        "new_scope";
        "scope:7";
        "select:3";
        "validate:7:4";
        "cleanup:7";
      ]
  | Compute_defect ->
      [
        "compute_source:3";
        "new_scope";
        "scope:7";
        "select:3";
        "validate:7:4";
        "compute:4";
        "cleanup:7";
      ]

let check_dynamic_switch_failure_runs_cleanup failure =
  let events = ref [] in
  let label = dynamic_switch_failure_name failure in
  let defect slot = Dynamic_switch_failure slot in
  let context =
    dynamic_contexts events
      ~selector_override:(fun source ->
        events := !events @ [ "select:" ^ string_of_int source ];
        match failure with
        | Selector_defect -> raise (defect "selector")
        | Validation_error | Validation_defect | Compute_defect ->
            source + 1)
      ~validate_inner_override:(fun cap scope inner ->
        check_cap cap;
        events :=
          !events
          @ [
              "validate:"
              ^ String.concat ":" (List.map string_of_int [ scope; inner ]);
            ];
        match failure with
        | Validation_error -> Error `Invalid_scope
        | Validation_defect -> raise (defect "validation")
        | Selector_defect | Compute_defect -> Ok ())
      ~compute_inner_override:(fun cap inner ->
        check_cap cap;
        events := !events @ [ "compute:" ^ string_of_int inner ];
        match failure with
        | Compute_defect -> raise (defect "compute")
        | Selector_defect | Validation_error | Validation_defect ->
            (inner * 10, false))
      ~on_switch_failure_override:(fun cap scope ->
        check_cap cap;
        events := !events @ [ "cleanup:" ^ string_of_int scope ])
  in
  (match failure with
  | Validation_error -> (
      match
        Bind.run_dynamic context capability Bind.empty
      with
      | Error `Invalid_scope -> ()
      | Ok _ -> Alcotest.failf "%s: expected invalid scope" label)
  | Selector_defect | Validation_defect | Compute_defect ->
      Alcotest.check_raises label
        (defect (dynamic_switch_failure_defect failure))
        (fun () ->
          ignore (Bind.run_dynamic context capability Bind.empty)));
  Alcotest.(check (list string))
    (label ^ ": events")
    (expected_dynamic_switch_failure_events failure)
    !events

let test_generated_dynamic_switch_failures_run_cleanup () =
  List.iter check_dynamic_switch_failure_runs_cleanup
    dynamic_switch_failure_cases

let () =
  Alcotest.run "eta_signal_bind"
    [
      ( "bind",
        [
          Alcotest.test_case "empty snapshot" `Quick test_empty_snapshot;
          Alcotest.test_case "switch snapshot" `Quick test_switch_snapshot;
          Alcotest.test_case "stage transaction switch remembers once" `Quick
            test_stage_transaction_switch_remembers_once;
          Alcotest.test_case "staged switch commit effects" `Quick
            test_staged_switch_commit_runs_graph_effects_in_bind_order;
          Alcotest.test_case "staged switch noop" `Quick
            test_staged_switch_no_staged_snapshot_is_noop;
          Alcotest.test_case "staged switch missing owner" `Quick
            test_staged_switch_rejects_missing_owner;
          Alcotest.test_case "staged switch preflight owner" `Quick
            test_staged_switch_preflight_uses_owner_for_old_scope;
          Alcotest.test_case "collect staged invalidations" `Quick
            test_collect_staged_switch_invalidations_collects_old_scopes;
          Alcotest.test_case "collect staged invalidations missing owner"
            `Quick
            test_collect_staged_switch_invalidations_rejects_missing_owner;
          Alcotest.test_case "incomplete switch rejected" `Quick
            test_staged_switch_rejects_incomplete_staged_snapshot;
          Alcotest.test_case "dependencies include source and inner" `Quick
            test_dependencies_include_source_and_current_inner;
          Alcotest.test_case "run dynamic switch" `Quick
            test_run_dynamic_switch_owns_eval_and_apply_order;
          Alcotest.test_case "run dynamic reuse" `Quick
            test_run_dynamic_reuse_paths;
          Alcotest.test_case "run dynamic dirty reuse" `Quick
            test_run_dynamic_dirty_reuse_recomputes_with_cutoff;
          Alcotest.test_case "generated dynamic switch failures" `Quick
            test_generated_dynamic_switch_failures_run_cleanup;
        ] );
    ]
