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
  match
    Bind.commit_staged_switch switch
      ~detach_old_inner:(fun owner inner ->
        record ("detach:" ^ owner ^ ":" ^ inner))
      ~invalidate_old_scope:(fun scope ->
        record ("invalidate:" ^ string_of_int scope);
        [ "cleanup:" ^ string_of_int scope ])
      ~attach_new_inner:(fun owner inner ->
        record ("attach:" ^ owner ^ ":" ^ inner))
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
  (match
     Bind.commit_staged_switch switch
       ~detach_old_inner:(fun _ _ -> effects := "detach" :: !effects)
       ~invalidate_old_scope:(fun _ ->
         effects := "invalidate" :: !effects;
         [])
       ~attach_new_inner:(fun _ _ -> effects := "attach" :: !effects)
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
     Bind.rollback_staged_switch ~staged:None ~invalidate_new_scope:(fun _ ->
         effects := "rollback" :: !effects;
         [])
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
  Alcotest.(check bool) "commit rejected" true
    (Result.is_error
       (Bind.commit_staged_switch switch
          ~detach_old_inner:(fun _ _ -> ())
          ~invalidate_old_scope:(fun _ -> [])
          ~attach_new_inner:(fun _ _ -> ())));
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
  Alcotest.(check bool) "commit rejected" true
    (Result.is_error
       (Bind.commit_staged_switch switch
          ~detach_old_inner:(fun _ _ -> ())
          ~invalidate_old_scope:(fun _ -> [])
          ~attach_new_inner:(fun _ _ -> ())));
  Alcotest.(check bool) "rollback rejected" true
    (Result.is_error
       (Bind.rollback_staged_switch ~staged:(Some Bind.empty)
          ~invalidate_new_scope:(fun _ -> [])));
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
    ?validate_inner_override ?on_switch_failure_override events =
  let with_scope, validate_inner, compute_inner, dependencies_changed =
    dynamic_common_callbacks ~inner_changed ~dependencies_changed events
  in
  let eval =
    Bind.dynamic_eval_context ~source_equal:Int.equal
      ~source_dependency:100
      ~pack_inner:(fun inner -> inner + 1000)
      ~new_scope:(fun cap ->
        check_cap cap;
        events := !events @ [ "new_scope" ];
        7)
      ~selector:(fun source ->
        events := !events @ [ "select:" ^ string_of_int source ];
        source + 1)
      ~with_scope:(fun cap scope f ->
        check_cap cap;
        with_scope scope f)
      ~validate_inner:
        (match validate_inner_override with
        | Some validate_inner -> validate_inner
        | None ->
            fun cap scope inner ->
              check_cap cap;
              validate_inner scope inner)
      ~compute_inner:(fun cap inner ->
        check_cap cap;
        compute_inner inner)
      ~on_switch_failure:
        (match on_switch_failure_override with
        | Some on_switch_failure -> on_switch_failure
        | None ->
            fun cap _scope ->
              check_cap cap;
              Alcotest.fail "unexpected cleanup")
      ~dirty ~initialized:(fun () -> initialized)
      ~dependencies_changed:(fun cap dependencies ->
        check_cap cap;
        dependencies_changed dependencies)
  in
  let apply =
    Bind.dynamic_apply_context ~current_value:(fun () -> current)
      ~cached_value:(fun () ->
        events := !events @ [ "cached" ];
        match current with
        | Some value -> value
        | None -> invalid_arg "missing current")
      ~initialized:(fun () -> initialized)
      ~value_equal:Int.equal
      ~bump_recompute:(fun () -> events := !events @ [ "bump" ])
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
  Bind.dynamic_context ~eval ~apply

let run_dynamic context snapshot ~source_value ~source_changed =
  match
    Bind.run_dynamic context capability snapshot ~source_value
      ~source_changed
  with
  | Ok result -> result
  | Error `Invalid_scope -> Alcotest.fail "expected valid dynamic bind"

let test_run_dynamic_switch_owns_eval_and_apply_order () =
  let events = ref [] in
  let context = dynamic_contexts events in
  Alcotest.(check (pair int bool)) "result" (40, true)
    (run_dynamic context Bind.empty ~source_value:3 ~source_changed:true);
  Alcotest.(check (list string))
    "events"
    [
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
  let missing_current = dynamic_contexts ~current:None events in
  Alcotest.(check (pair int bool))
    "cached result" (-1, false)
    (run_dynamic cached snapshot ~source_value:3 ~source_changed:false);
  Alcotest.(check (pair int bool))
    "recomputed result" (40, true)
    (run_dynamic recomputed snapshot ~source_value:3 ~source_changed:false);
  Alcotest.check_raises "cached missing current"
    (Invalid_argument "missing current")
    (fun () ->
      ignore
        (run_dynamic missing_current snapshot ~source_value:3
           ~source_changed:false));
  Alcotest.(check (list string))
    "events"
    [
      "compute:4";
      "dependencies:100,1004";
      "cached";
      "compute:4";
      "dependencies:100,1004";
      "bump";
      "stage_dependencies:100,1004";
      "stage_value:40";
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
    (run_dynamic context snapshot ~source_value:3 ~source_changed:false);
  Alcotest.(check (list string))
    "events"
    [
      "compute:4";
      "bump";
      "stage_dependencies:100,1004";
      "cached";
    ]
    !events

let test_run_dynamic_validation_failure_runs_cleanup () =
  let events = ref [] in
  let context =
    dynamic_contexts events
      ~validate_inner_override:(fun cap scope inner ->
        check_cap cap;
        events :=
          !events
          @ [
              "validate:"
              ^ String.concat ":" (List.map string_of_int [ scope; inner ]);
            ];
        Error `Invalid_scope)
      ~on_switch_failure_override:(fun cap scope ->
        check_cap cap;
        events := !events @ [ "cleanup:" ^ string_of_int scope ])
  in
  (match
     Bind.run_dynamic context capability Bind.empty
       ~source_value:3 ~source_changed:true
   with
  | Error `Invalid_scope -> ()
  | Ok _ -> Alcotest.fail "expected invalid scope");
  Alcotest.(check (list string))
    "events"
    [
      "new_scope";
      "scope:7";
      "select:3";
      "validate:7:4";
      "cleanup:7";
    ]
    !events

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
          Alcotest.test_case "run dynamic validation failure" `Quick
            test_run_dynamic_validation_failure_runs_cleanup;
        ] );
    ]
