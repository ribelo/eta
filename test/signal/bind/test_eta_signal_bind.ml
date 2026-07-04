module Bind = Eta_signal_bind

let test_empty_snapshot () =
  let snapshot = Bind.empty in
  Alcotest.(check (option int)) "source value" None
    (Bind.source_value snapshot);
  Alcotest.(check (option string)) "inner" None (Bind.inner snapshot);
  Alcotest.(check (option int)) "scope" None (Bind.inner_scope snapshot);
  Alcotest.(check bool) "needs initial inner" true
    (Bind.needs_new_inner ~equal:Int.equal snapshot 1);
  Alcotest.(check bool) "no switch parts" true
    (Option.is_none (Bind.switch_parts snapshot))

let test_switch_snapshot () =
  let snapshot = Bind.switch ~source_value:1 ~inner:"inner" ~scope:2 in
  Alcotest.(check (option int)) "source value" (Some 1)
    (Bind.source_value snapshot);
  Alcotest.(check (option string)) "inner" (Some "inner")
    (Bind.inner snapshot);
  Alcotest.(check (option int)) "scope" (Some 2) (Bind.inner_scope snapshot);
  Alcotest.(check bool) "same source reuses inner" false
    (Bind.needs_new_inner ~equal:Int.equal snapshot 1);
  Alcotest.(check bool) "changed source needs inner" true
    (Bind.needs_new_inner ~equal:Int.equal snapshot 2);
  match Bind.switch_parts snapshot with
  | Some (source_value, inner, scope) ->
      Alcotest.(check int) "switch source" 1 source_value;
      Alcotest.(check string) "switch inner" "inner" inner;
      Alcotest.(check int) "switch scope" 2 scope
  | None -> Alcotest.fail "expected complete switch parts"

let test_eval_plan_switches_for_initial_or_changed_source () =
  let initial_plan =
    Bind.eval_plan ~equal:Int.equal Bind.empty ~source_value:1
  in
  let changed_plan =
    Bind.eval_plan ~equal:Int.equal
      (Bind.switch ~source_value:1 ~inner:"old" ~scope:2)
      ~source_value:2
  in
  (match initial_plan with
  | Ok Bind.Switch -> ()
  | Ok (Bind.Reuse _) -> Alcotest.fail "expected initial switch"
  | Error `Invalid_scope -> Alcotest.fail "expected valid initial switch");
  match changed_plan with
  | Ok Bind.Switch -> ()
  | Ok (Bind.Reuse _) -> Alcotest.fail "expected changed switch"
  | Error `Invalid_scope -> Alcotest.fail "expected valid changed switch"

let test_eval_plan_reuses_inner_for_equal_source () =
  let snapshot = Bind.switch ~source_value:1 ~inner:"inner" ~scope:2 in
  match Bind.eval_plan ~equal:Int.equal snapshot ~source_value:1 with
  | Ok (Bind.Reuse inner) -> Alcotest.(check string) "inner" "inner" inner
  | Ok Bind.Switch -> Alcotest.fail "expected reuse"
  | Error `Invalid_scope -> Alcotest.fail "expected valid reuse"

let test_switch_commit_runs_graph_effects_in_bind_order () =
  let current = Bind.switch ~source_value:0 ~inner:"old" ~scope:1 in
  let staged = Bind.switch ~source_value:1 ~inner:"new" ~scope:2 in
  let effects = ref [] in
  let record effect = effects := !effects @ [ effect ] in
  match
    Bind.commit_switch ~current ~staged
      ~detach_old_inner:(fun inner -> record ("detach:" ^ inner))
      ~invalidate_old_scope:(fun scope ->
        record ("invalidate:" ^ string_of_int scope);
        [ "cleanup:" ^ string_of_int scope ])
      ~attach_new_inner:(fun inner -> record ("attach:" ^ inner))
  with
  | Ok hooks ->
      Alcotest.(check (list string))
        "effect order"
        [ "detach:old"; "invalidate:1"; "attach:new" ]
        !effects;
      Alcotest.(check (list string)) "hooks" [ "cleanup:1" ] hooks
  | Error `Invalid_scope -> Alcotest.fail "expected commit plan"

let test_switch_rollback_and_preflight_plans () =
  let current = Bind.switch ~source_value:0 ~inner:"old" ~scope:1 in
  let staged = Bind.switch ~source_value:1 ~inner:"new" ~scope:2 in
  let rolled_back = ref [] in
  (match
     Bind.rollback_switch ~staged ~invalidate_new_scope:(fun scope ->
         rolled_back := scope :: !rolled_back;
         [ "cleanup:" ^ string_of_int scope ])
   with
  | Ok hooks ->
      Alcotest.(check (list int)) "rollback scope" [ 2 ] !rolled_back;
      Alcotest.(check (list string)) "rollback hooks" [ "cleanup:2" ] hooks
  | Error `Invalid_scope -> Alcotest.fail "expected rollback scope");
  let preflighted = ref [] in
  match
    Bind.preflight_switch ~current ~staged
      ~collect_old_scope:(fun scope -> preflighted := scope :: !preflighted)
  with
  | Ok () -> Alcotest.(check (list int)) "preflight old scope" [ 1 ] !preflighted
  | Error `Invalid_scope -> Alcotest.fail "expected preflight scope"

let test_stage_switch_remembers_before_staging_snapshot () =
  let effects = ref [] in
  let staged_snapshot = ref None in
  Bind.stage_switch
    ~remember:(fun () -> effects := !effects @ [ "remember" ])
    ~stage:(fun snapshot ->
      effects := !effects @ [ "stage" ];
      staged_snapshot := Some snapshot)
    ~source_value:1 ~inner:"inner" ~scope:2;
  Alcotest.(check (list string))
    "effect order" [ "remember"; "stage" ] !effects;
  match !staged_snapshot with
  | Some snapshot -> (
      match Bind.switch_parts snapshot with
      | Some (source_value, inner, scope) ->
          Alcotest.(check int) "source" 1 source_value;
          Alcotest.(check string) "inner" "inner" inner;
          Alcotest.(check int) "scope" 2 scope
      | None -> Alcotest.fail "expected staged switch")
  | None -> Alcotest.fail "expected staged snapshot"

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

let test_switch_plans_reject_incomplete_staged_snapshot () =
  let current = Bind.switch ~source_value:0 ~inner:"old" ~scope:1 in
  Alcotest.(check bool) "commit rejected" true
    (Result.is_error
       (Bind.commit_switch ~current ~staged:Bind.empty
          ~detach_old_inner:(fun _ -> ())
          ~invalidate_old_scope:(fun _ -> [])
          ~attach_new_inner:(fun _ -> ())));
  Alcotest.(check bool) "rollback rejected" true
    (Result.is_error
       (Bind.rollback_switch ~staged:Bind.empty
          ~invalidate_new_scope:(fun _ -> [])));
  Alcotest.(check bool) "preflight rejected" true
    (Result.is_error
       (Bind.preflight_switch ~current ~staged:Bind.empty
          ~collect_old_scope:(fun _ -> ())))

let test_dependencies_include_source_and_current_inner () =
  Alcotest.(check (list int))
    "source only" [ 1 ]
    (Bind.dependencies ~source:1 ~inner:None);
  Alcotest.(check (list int))
    "source then inner" [ 1; 2 ]
    (Bind.dependencies ~source:1 ~inner:(Some 2))

let test_eval_switch_runs_selector_in_scope_and_computes_inner () =
  let entered_scope = ref None in
  let validated = ref None in
  let with_scope scope f =
    entered_scope := Some scope;
    f ()
  in
  match
    Bind.eval_switch ~scope:7 ~source_value:3
      ~selector:(fun source -> "inner-" ^ string_of_int source)
      ~with_scope
      ~validate_inner:(fun scope inner ->
        validated := Some (scope, inner);
        Ok ())
      ~compute_inner:(fun inner -> (String.length inner, true))
      ~on_failure:(fun _ -> Alcotest.fail "unexpected cleanup")
  with
  | Ok eval ->
      Alcotest.(check (option int)) "entered scope" (Some 7) !entered_scope;
      Alcotest.(check (option (pair int string)))
        "validated inner" (Some (7, "inner-3")) !validated;
      Alcotest.(check string) "inner" "inner-3" eval.Bind.eval_inner;
      Alcotest.(check int) "value" 7 eval.Bind.eval_value
  | Error `Invalid_scope -> Alcotest.fail "expected successful switch eval"

let test_eval_switch_validation_failure_runs_cleanup () =
  let cleaned = ref [] in
  match
    Bind.eval_switch ~scope:11 ~source_value:1
      ~selector:(fun source -> source + 1)
      ~with_scope:(fun _ f -> f ())
      ~validate_inner:(fun _ _ -> Error `Invalid_scope)
      ~compute_inner:(fun _ -> Alcotest.fail "compute should not run")
      ~on_failure:(fun scope -> cleaned := scope :: !cleaned)
  with
  | Ok _ -> Alcotest.fail "expected invalid scope"
  | Error `Invalid_scope ->
      Alcotest.(check (list int)) "cleaned scope" [ 11 ] !cleaned

let test_eval_switch_selector_exception_runs_cleanup () =
  let cleaned = ref [] in
  Alcotest.check_raises "selector failure" Exit (fun () ->
      ignore
        (Bind.eval_switch ~scope:13 ~source_value:1
           ~selector:(fun _ -> raise Exit)
           ~with_scope:(fun _ f -> f ())
           ~validate_inner:(fun _ _ -> Ok ())
           ~compute_inner:(fun _ -> Alcotest.fail "compute should not run")
           ~on_failure:(fun scope -> cleaned := scope :: !cleaned)
          : ((int, int) Bind.switch_eval, [> `Invalid_scope ]) result));
  Alcotest.(check (list int)) "cleaned scope" [ 13 ] !cleaned

let test_eval_switch_compute_exception_runs_cleanup () =
  let cleaned = ref [] in
  Alcotest.check_raises "compute failure" Exit (fun () ->
      ignore
        (Bind.eval_switch ~scope:17 ~source_value:1
           ~selector:(fun source -> source + 1)
           ~with_scope:(fun _ f -> f ())
           ~validate_inner:(fun _ _ -> Ok ())
           ~compute_inner:(fun _ -> raise Exit)
           ~on_failure:(fun scope -> cleaned := scope :: !cleaned)
          : ((int, int) Bind.switch_eval, [> `Invalid_scope ]) result));
  Alcotest.(check (list int)) "cleaned scope" [ 17 ] !cleaned

let check_reuse_recompute label ~expected_dependencies ~expected_value = function
  | Bind.Reuse_recompute { reuse_dependencies; reuse_value } ->
      Alcotest.(check (list int))
        (label ^ " dependencies")
        expected_dependencies reuse_dependencies;
      Alcotest.(check int) (label ^ " value") expected_value reuse_value
  | Bind.Reuse_cached -> Alcotest.fail (label ^ ": expected recompute")

let check_reuse_cached label = function
  | Bind.Reuse_cached -> ()
  | Bind.Reuse_recompute _ -> Alcotest.fail (label ^ ": expected cached")

let eval_reuse ?(source_changed = false) ?(dirty = false) ?(initialized = true)
    ?(inner_changed = false) ?(dependencies_changed = false) () =
  let computed = ref false in
  let plan =
    Bind.eval_reuse ~source_dependency:1 ~inner_dependency:2 ~source_changed
      ~compute_inner:(fun () ->
        computed := true;
        (42, inner_changed))
      ~dirty ~initialized
      ~dependencies_changed:(fun dependencies ->
        Alcotest.(check (list int)) "dependency predicate input" [ 1; 2 ]
          dependencies;
        dependencies_changed)
  in
  Alcotest.(check bool) "inner computed" true !computed;
  plan

let test_eval_reuse_uses_cached_when_unchanged () =
  check_reuse_cached "cached" (eval_reuse ())

let test_eval_reuse_recomputes_for_dirty_source_or_inner_change () =
  check_reuse_recompute "dirty" ~expected_dependencies:[ 1; 2 ]
    ~expected_value:42 (eval_reuse ~dirty:true ());
  check_reuse_recompute "source changed" ~expected_dependencies:[ 1; 2 ]
    ~expected_value:42 (eval_reuse ~source_changed:true ());
  check_reuse_recompute "inner changed" ~expected_dependencies:[ 1; 2 ]
    ~expected_value:42 (eval_reuse ~inner_changed:true ())

let test_eval_reuse_recomputes_for_uninitialized_or_dependency_change () =
  check_reuse_recompute "uninitialized" ~expected_dependencies:[ 1; 2 ]
    ~expected_value:42 (eval_reuse ~initialized:false ());
  check_reuse_recompute "dependency changed" ~expected_dependencies:[ 1; 2 ]
    ~expected_value:42 (eval_reuse ~dependencies_changed:true ())

let () =
  Alcotest.run "eta_signal_bind"
    [
      ( "bind",
        [
          Alcotest.test_case "empty snapshot" `Quick test_empty_snapshot;
          Alcotest.test_case "switch snapshot" `Quick test_switch_snapshot;
          Alcotest.test_case "eval plan switches" `Quick
            test_eval_plan_switches_for_initial_or_changed_source;
          Alcotest.test_case "eval plan reuses" `Quick
            test_eval_plan_reuses_inner_for_equal_source;
          Alcotest.test_case "switch commit effects" `Quick
            test_switch_commit_runs_graph_effects_in_bind_order;
          Alcotest.test_case "switch rollback and preflight plans" `Quick
            test_switch_rollback_and_preflight_plans;
          Alcotest.test_case "stage switch remembers first" `Quick
            test_stage_switch_remembers_before_staging_snapshot;
          Alcotest.test_case "staged switch commit effects" `Quick
            test_staged_switch_commit_runs_graph_effects_in_bind_order;
          Alcotest.test_case "staged switch noop" `Quick
            test_staged_switch_no_staged_snapshot_is_noop;
          Alcotest.test_case "staged switch missing owner" `Quick
            test_staged_switch_rejects_missing_owner;
          Alcotest.test_case "staged switch preflight owner" `Quick
            test_staged_switch_preflight_uses_owner_for_old_scope;
          Alcotest.test_case "incomplete switch rejected" `Quick
            test_switch_plans_reject_incomplete_staged_snapshot;
          Alcotest.test_case "dependencies include source and inner" `Quick
            test_dependencies_include_source_and_current_inner;
          Alcotest.test_case "eval switch runs scoped selector" `Quick
            test_eval_switch_runs_selector_in_scope_and_computes_inner;
          Alcotest.test_case "eval switch validation cleanup" `Quick
            test_eval_switch_validation_failure_runs_cleanup;
          Alcotest.test_case "eval switch selector cleanup" `Quick
            test_eval_switch_selector_exception_runs_cleanup;
          Alcotest.test_case "eval switch compute cleanup" `Quick
            test_eval_switch_compute_exception_runs_cleanup;
          Alcotest.test_case "eval reuse cached" `Quick
            test_eval_reuse_uses_cached_when_unchanged;
          Alcotest.test_case "eval reuse recompute changes" `Quick
            test_eval_reuse_recomputes_for_dirty_source_or_inner_change;
          Alcotest.test_case "eval reuse recompute initialization" `Quick
            test_eval_reuse_recomputes_for_uninitialized_or_dependency_change;
        ] );
    ]
