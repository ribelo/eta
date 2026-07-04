module Bind = Eta_signal_bind
module T = Eta_signal_transaction

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
  let switch = { Bind.owner = Some "owner"; current; staged = Some staged } in
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
  let switch = { Bind.owner = None; current; staged = None } in
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
  let switch = { Bind.owner = None; current; staged = Some staged } in
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
  let switch = { Bind.owner = Some "owner"; current; staged = Some staged } in
  match
    Bind.preflight_staged_switch switch ~collect_old_scope:(fun owner scope ->
        collected := (owner, scope) :: !collected)
  with
  | Ok () ->
      Alcotest.(check (list (pair string int)))
        "collected" [ ("owner", 1) ] !collected
  | Error `Invalid_scope -> Alcotest.fail "expected preflight"

let packed_staged_switch switch = Bind.Packed_staged_switch switch

let test_collect_staged_switch_invalidations_collects_old_scopes () =
  let first =
    {
      Bind.owner = Some "first";
      current = Bind.switch ~source_value:0 ~inner:"old-first" ~scope:1;
      staged = Some (Bind.switch ~source_value:1 ~inner:"new-first" ~scope:10);
    }
  in
  let unstaged =
    {
      Bind.owner = Some "unstaged";
      current = Bind.switch ~source_value:0 ~inner:"old-unstaged" ~scope:2;
      staged = None;
    }
  in
  let second =
    {
      Bind.owner = Some "second";
      current = Bind.switch ~source_value:0 ~inner:"old-second" ~scope:3;
      staged = Some (Bind.switch ~source_value:1 ~inner:"new-second" ~scope:30);
    }
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
    {
      Bind.owner = None;
      current = Bind.switch ~source_value:0 ~inner:"old" ~scope:1;
      staged = Some (Bind.switch ~source_value:1 ~inner:"new" ~scope:2);
    }
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
    { Bind.owner = Some "owner"; current; staged = Some Bind.empty }
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

let test_eval_dynamic_switch_owns_scope_validation_and_dependencies () =
  let events = ref [] in
  let with_scope, validate_inner, compute_inner, dependencies_changed =
    dynamic_common_callbacks events
  in
  match
    Bind.eval_dynamic ~equal:Int.equal Bind.empty ~source_dependency:100
      ~pack_inner:(fun inner -> inner + 1000)
      ~source_value:3 ~source_changed:true
      ~new_scope:(fun () ->
        events := !events @ [ "new_scope" ];
        7)
      ~selector:(fun source ->
        events := !events @ [ "select:" ^ string_of_int source ];
        source + 1)
      ~with_scope ~validate_inner ~compute_inner
      ~on_switch_failure:(fun _scope -> Alcotest.fail "unexpected cleanup")
      ~dirty:false ~initialized:true ~dependencies_changed
  with
  | Ok
      (Bind.Dynamic_switch
        {
          dynamic_source_value;
          dynamic_inner;
          dynamic_scope;
          dynamic_switch_dependencies;
          dynamic_switch_value;
        }) ->
      Alcotest.(check int) "source" 3 dynamic_source_value;
      Alcotest.(check int) "inner" 4 dynamic_inner;
      Alcotest.(check int) "scope" 7 dynamic_scope;
      Alcotest.(check (list int))
        "dependencies" [ 100; 1004 ] dynamic_switch_dependencies;
      Alcotest.(check int) "value" 40 dynamic_switch_value;
      Alcotest.(check (list string))
        "events"
        [ "new_scope"; "scope:7"; "select:3"; "validate:7:4"; "compute:4" ]
        !events
  | Ok Bind.Dynamic_reuse_cached | Ok (Bind.Dynamic_reuse_recompute _) ->
      Alcotest.fail "expected dynamic switch"
  | Error `Invalid_scope -> Alcotest.fail "expected valid dynamic switch"

let test_eval_dynamic_reuse_cached () =
  let events = ref [] in
  let with_scope, validate_inner, compute_inner, dependencies_changed =
    dynamic_common_callbacks events
  in
  let snapshot = Bind.switch ~source_value:3 ~inner:4 ~scope:7 in
  match
    Bind.eval_dynamic ~equal:Int.equal snapshot ~source_dependency:100
      ~pack_inner:(fun inner -> inner + 1000)
      ~source_value:3 ~source_changed:false
      ~new_scope:(fun () -> Alcotest.fail "scope should be reused")
      ~selector:(fun _ -> Alcotest.fail "selector should not run")
      ~with_scope ~validate_inner ~compute_inner
      ~on_switch_failure:(fun _ -> Alcotest.fail "unexpected cleanup")
      ~dirty:false ~initialized:true ~dependencies_changed
  with
  | Ok Bind.Dynamic_reuse_cached ->
      Alcotest.(check (list string))
        "events" [ "compute:4"; "dependencies:100,1004" ] !events
  | Ok (Bind.Dynamic_switch _) | Ok (Bind.Dynamic_reuse_recompute _) ->
      Alcotest.fail "expected cached reuse"
  | Error `Invalid_scope -> Alcotest.fail "expected valid reuse"

let test_eval_dynamic_reuse_recomputes_with_dependencies () =
  let events = ref [] in
  let with_scope, validate_inner, compute_inner, dependencies_changed =
    dynamic_common_callbacks ~dependencies_changed:true events
  in
  let snapshot = Bind.switch ~source_value:3 ~inner:4 ~scope:7 in
  match
    Bind.eval_dynamic ~equal:Int.equal snapshot ~source_dependency:100
      ~pack_inner:(fun inner -> inner + 1000)
      ~source_value:3 ~source_changed:false
      ~new_scope:(fun () -> Alcotest.fail "scope should be reused")
      ~selector:(fun _ -> Alcotest.fail "selector should not run")
      ~with_scope ~validate_inner ~compute_inner
      ~on_switch_failure:(fun _ -> Alcotest.fail "unexpected cleanup")
      ~dirty:false ~initialized:true ~dependencies_changed
  with
  | Ok
      (Bind.Dynamic_reuse_recompute
        { dynamic_reuse_dependencies; dynamic_reuse_value }) ->
      Alcotest.(check (list int))
        "dependencies" [ 100; 1004 ] dynamic_reuse_dependencies;
      Alcotest.(check int) "value" 40 dynamic_reuse_value;
      Alcotest.(check (list string))
        "events" [ "compute:4"; "dependencies:100,1004" ] !events
  | Ok (Bind.Dynamic_switch _) | Ok Bind.Dynamic_reuse_cached ->
      Alcotest.fail "expected recomputed reuse"
  | Error `Invalid_scope -> Alcotest.fail "expected valid reuse"

let dynamic_apply_callbacks ?(changed = true) ?(current = -1) events =
  {
    Bind.dynamic_mark_recomputed =
      (fun () -> events := !events @ [ "mark_recomputed" ]);
    dynamic_switch_changed =
      (fun value ->
        events :=
          !events @ [ "changed:" ^ string_of_int value ];
        changed);
    dynamic_stage_switch =
      (fun ~source_value ~inner ~scope ->
        events :=
          !events
          @ [
              "stage_switch:"
              ^ String.concat ":"
                  (List.map string_of_int [ source_value; inner; scope ]);
            ]);
    dynamic_stage_dependencies =
      (fun dependencies ->
        events :=
          !events
          @ [
              "stage_dependencies:"
              ^ String.concat ","
                  (List.map string_of_int dependencies);
            ]);
    dynamic_stage_value =
      (fun value ->
        events :=
          !events @ [ "stage_value:" ^ string_of_int value ]);
    dynamic_current_value =
      (fun () ->
        events := !events @ [ "current" ];
        current);
    dynamic_recompute_with_dependencies =
      (fun dependencies value ->
        events :=
          !events
          @ [
              "recompute:"
              ^ String.concat ","
                  (List.map string_of_int dependencies)
              ^ ":" ^ string_of_int value;
            ];
        (value + 1, true));
    dynamic_use_cached =
      (fun () ->
        events := !events @ [ "cached" ];
        (current, false));
  }

let test_apply_dynamic_eval_switch_stages_in_bind_order () =
  let events = ref [] in
  let value, changed =
    Bind.apply_dynamic_eval (dynamic_apply_callbacks events)
      (Bind.Dynamic_switch
         {
           dynamic_source_value = 3;
           dynamic_inner = 4;
           dynamic_scope = 7;
           dynamic_switch_dependencies = [ 100; 1004 ];
           dynamic_switch_value = 40;
         })
  in
  Alcotest.(check int) "value" 40 value;
  Alcotest.(check bool) "changed" true changed;
  Alcotest.(check (list string))
    "events"
    [
      "mark_recomputed";
      "changed:40";
      "stage_switch:3:4:7";
      "stage_dependencies:100,1004";
      "stage_value:40";
    ]
    !events

let test_apply_dynamic_eval_switch_stages_dependencies_when_unchanged () =
  let events = ref [] in
  let value, changed =
    Bind.apply_dynamic_eval
      (dynamic_apply_callbacks ~changed:false ~current:39 events)
      (Bind.Dynamic_switch
         {
           dynamic_source_value = 3;
           dynamic_inner = 4;
           dynamic_scope = 7;
           dynamic_switch_dependencies = [ 100; 1004 ];
           dynamic_switch_value = 40;
         })
  in
  Alcotest.(check int) "value" 39 value;
  Alcotest.(check bool) "changed" false changed;
  Alcotest.(check (list string))
    "events"
    [
      "mark_recomputed";
      "changed:40";
      "stage_switch:3:4:7";
      "stage_dependencies:100,1004";
      "current";
    ]
    !events

let test_apply_dynamic_eval_reuse_delegates_to_recompute_or_cache () =
  let events = ref [] in
  let recomputed_value, recomputed_changed =
    Bind.apply_dynamic_eval (dynamic_apply_callbacks events)
      (Bind.Dynamic_reuse_recompute
         {
           dynamic_reuse_dependencies = [ 100; 1004 ];
           dynamic_reuse_value = 40;
         })
  in
  let cached_value, cached_changed =
    Bind.apply_dynamic_eval
      (dynamic_apply_callbacks ~current:12 events)
      Bind.Dynamic_reuse_cached
  in
  Alcotest.(check int) "recomputed value" 41 recomputed_value;
  Alcotest.(check bool) "recomputed changed" true recomputed_changed;
  Alcotest.(check int) "cached value" 12 cached_value;
  Alcotest.(check bool) "cached changed" false cached_changed;
  Alcotest.(check (list string))
    "events" [ "recompute:100,1004:40"; "cached" ] !events

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
          Alcotest.test_case "eval dynamic switch plan" `Quick
            test_eval_dynamic_switch_owns_scope_validation_and_dependencies;
          Alcotest.test_case "eval dynamic reuse cached" `Quick
            test_eval_dynamic_reuse_cached;
          Alcotest.test_case "eval dynamic reuse recompute" `Quick
            test_eval_dynamic_reuse_recomputes_with_dependencies;
          Alcotest.test_case "apply dynamic switch order" `Quick
            test_apply_dynamic_eval_switch_stages_in_bind_order;
          Alcotest.test_case "apply dynamic unchanged switch" `Quick
            test_apply_dynamic_eval_switch_stages_dependencies_when_unchanged;
          Alcotest.test_case "apply dynamic reuse" `Quick
            test_apply_dynamic_eval_reuse_delegates_to_recompute_or_cache;
        ] );
    ]
