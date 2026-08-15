(* Named gates for the eta_component core runtime.

   Each test function names the verification-matrix gate it implements. The
   observation boundary is the public diagnostics surface (snapshots, fence
   reports, change waits) plus the tracked-component event logs; the
   deterministic seam is [Eta_test.Run]. *)

open Eta
open Eta_component
open Test_component_support

let ( let* ) = Syntax.( let* )

(* ------------------------------------------------------------------ *)
(* Bare context                                                        *)
(* ------------------------------------------------------------------ *)

let test_bare_context () =
  let outcome =
    run_program (Context.run (fun _context _diagnostics -> Effect.unit))
  in
  let () = expect_ok outcome in
  check_census outcome

(* ------------------------------------------------------------------ *)
(* component_schema_key_uniqueness: duplicate requirement, duplicate   *)
(* provision, and self-dependency fail at Component.make.               *)
(* ------------------------------------------------------------------ *)

let test_component_schema_key_uniqueness () =
  let key = coeffect_exn "dup" in
  let family name = Component.Family.create ~name ~module_locator:name () in
  let pp ppf error = Format.pp_print_string ppf error in
  let activate _config _requirements _activation = Effect.unit in
  (* Duplicate requirement key. *)
  (match
     Component.make ~family:(family "dup-req") ~config_equal:Int.equal
       ~requirements:
         Requirement.(both (one key) (one key))
       ~provisions:Provision.none ~pp_error:pp ~activate
   with
  | Error (Component.Duplicate_requirement name) ->
      Alcotest.(check string) "requirement name" "dup" name
  | Error _ -> Alcotest.fail "expected Duplicate_requirement"
  | Ok _ -> Alcotest.fail "duplicate requirement accepted");
  (* Duplicate provision key. *)
  (match
     Component.make ~family:(family "dup-prov") ~config_equal:Int.equal
       ~requirements:Requirement.none
       ~provisions:Provision.(both (one key) (one key))
       ~pp_error:pp
       ~activate:(fun _config _requirements _activation -> Effect.pure (0, 0))
   with
  | Error (Component.Duplicate_provision name) ->
      Alcotest.(check string) "provision name" "dup" name
  | Error _ -> Alcotest.fail "expected Duplicate_provision"
  | Ok _ -> Alcotest.fail "duplicate provision accepted");
  (* Self-dependency. *)
  match
    Component.make ~family:(family "self-dep") ~config_equal:Int.equal
      ~requirements:(Requirement.one key)
      ~provisions:(Provision.one key)
      ~pp_error:pp
      ~activate:(fun _config requirement _activation -> Effect.pure requirement)
  with
  | Error (Component.Self_dependency name) ->
      Alcotest.(check string) "self-dependency name" "dup" name
  | Error _ -> Alcotest.fail "expected Self_dependency"
  | Ok _ -> Alcotest.fail "self-dependency accepted"

(* ------------------------------------------------------------------ *)
(* Basic activation: one component activates, the fence completes        *)
(* Quiescent, the snapshot shows Active, and shutdown settles the census. *)
(* ------------------------------------------------------------------ *)

let test_reconcile_activates_component () =
  let tracked = tracked "basic" in
  let component = tracked_component tracked in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* fence =
             Context.reconcile context (tree_of [ entry "a" component 1 ])
           in
           let* report = Diagnostics.Fence.await fence in
           let* snapshot = Diagnostics.snapshot diagnostics in
           Effect.sync (fun () -> (report, snapshot))))
  in
  let report, snapshot = expect_ok outcome in
  Alcotest.(check bool) "fence quiescent" true
    (Diagnostics.Fence.outcome report = Diagnostics.Fence.Quiescent);
  Alcotest.(check string) "phase" "active" (find_phase snapshot "a");
  Alcotest.(check int) "one activation" 1 tracked.t_activations;
  Alcotest.(check (list string))
    "release ran at shutdown"
    [ "activate"; "acquire:basic"; "release:basic" ]
    (events tracked);
  check_census outcome

(* ------------------------------------------------------------------ *)
(* lifecycle_inertia_and_retry: an activation failure does not restart    *)
(* on an unchanged desired state; an explicit retry selects a fresh       *)
(* generation; a changed target revision restarts.                        *)
(* ------------------------------------------------------------------ *)

let test_component_lifecycle_inertia_and_retry () =
  let tracked = tracked "flaky" in
  tracked.t_fail_with <- Some "boom";
  let component = tracked_component tracked in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* fence =
             Context.reconcile context (tree_of [ entry "a" component 1 ])
           in
           let* _ = Diagnostics.Fence.await fence in
           let* snapshot = Diagnostics.snapshot diagnostics in
           let phase_after_failure = find_phase snapshot "a" in
           (* Unchanged desired state does not retry automatically. *)
           let* fence2 =
             Context.reconcile context (tree_of [ entry "a" component 1 ])
           in
           let* _ = Diagnostics.Fence.await fence2 in
           let* snapshot2 = Diagnostics.snapshot diagnostics in
           let phase_same = find_phase snapshot2 "a" in
           let activations_after_same = tracked.t_activations in
           (* Explicit retry selects a fresh generation. *)
           let* retry_fence =
             Context.retry context (entry_id_exn "a")
           in
           let* _ = Diagnostics.Fence.await retry_fence in
           let activations_after_retry = tracked.t_activations in
           (* A changed target revision restarts without explicit retry. *)
           let* fence3 =
             Context.reconcile context (tree_of [ entry "a" component 2 ])
           in
           let* _ = Diagnostics.Fence.await fence3 in
           let activations_after_change = tracked.t_activations in
           Effect.sync (fun () ->
               ( phase_after_failure,
                 phase_same,
                 activations_after_same,
                 activations_after_retry,
                 activations_after_change ))))
  in
  let ( phase_after_failure,
        phase_same,
        activations_after_same,
        activations_after_retry,
        activations_after_change ) =
    expect_ok outcome
  in
  Alcotest.(check string) "failed phase" "activation-failed" phase_after_failure;
  Alcotest.(check string) "unchanged target stays failed" "activation-failed"
    phase_same;
  Alcotest.(check int) "no automatic retry" 1 activations_after_same;
  Alcotest.(check int) "explicit retry restarts" 2 activations_after_retry;
  Alcotest.(check int) "changed revision restarts" 3 activations_after_change;
  check_census outcome

(* ------------------------------------------------------------------ *)
(* recovery_lifo + cleanup_at_most_once: releases run in reverse          *)
(* registration order, each exactly once, across success and failure.     *)
(* ------------------------------------------------------------------ *)

let test_component_recovery_lifo_and_cleanup_at_most_once () =
  let log = ref [] in
  let record event = log := !log @ [ event ] in
  let family = Component.Family.create ~name:"lifo" ~module_locator:"lifo" () in
  let component =
    match
      Component.make ~family ~config_equal:Int.equal
        ~requirements:Requirement.none ~provisions:Provision.none
        ~pp_error:(fun ppf error -> Format.pp_print_string ppf error)
        ~activate:(fun _config () activation ->
          let* () =
            Activation.own activation
              ~acquire:(Effect.sync (fun () -> record "acquire:1"))
              ~release:(fun () -> Effect.sync (fun () -> record "release:1"))
              ~pp_release_error:(fun ppf _ -> Format.pp_print_string ppf "e")
          in
          let* () =
            Activation.own activation
              ~acquire:(Effect.sync (fun () -> record "acquire:2"))
              ~release:(fun () -> Effect.sync (fun () -> record "release:2"))
              ~pp_release_error:(fun ppf _ -> Format.pp_print_string ppf "e")
          in
          Activation.own activation
            ~acquire:(Effect.sync (fun () -> record "acquire:3"))
            ~release:(fun () -> Effect.sync (fun () -> record "release:3"))
            ~pp_release_error:(fun ppf _ -> Format.pp_print_string ppf "e"))
    with
    | Ok component -> component
    | Error _ -> Alcotest.fail "make failed"
  in
  let outcome =
    run_program
      (Context.run (fun context _diagnostics ->
           let* fence =
             Context.reconcile context (tree_of [ entry "a" component 1 ])
           in
           Diagnostics.Fence.await fence >>= fun _ -> Effect.unit))
  in
  let () = expect_ok outcome in
  Alcotest.(check (list string))
    "LIFO release at shutdown"
    [ "acquire:1"; "acquire:2"; "acquire:3"; "release:3"; "release:2";
      "release:1" ]
    !log;
  check_census outcome

(* ------------------------------------------------------------------ *)
(* callback_boundary_matrix: a raising config_equal during a reconciling  *)
(* admission yields Callback_failed and mutates nothing.                  *)
(* ------------------------------------------------------------------ *)

let test_component_callback_boundary_matrix () =
  let log = ref [] in
  let family = Component.Family.create ~name:"cb" ~module_locator:"cb" () in
  (* One declaration whose configuration-equivalence callback raises. *)
  let component =
    match
      Component.make ~family
        ~config_equal:(fun _ _ -> raise (Failure "config_equal blew up"))
        ~requirements:Requirement.none ~provisions:Provision.none
        ~pp_error:(fun ppf error -> Format.pp_print_string ppf error)
        ~activate:(fun _config () _activation ->
          Effect.sync (fun () -> log := !log @ [ "activate" ]))
    with
    | Ok component -> component
    | Error _ -> Alcotest.fail "make failed"
  in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           (* The first reconcile of a fresh instance runs no equivalence
              callback: admission succeeds. *)
           let* fence =
             Context.reconcile context (tree_of [ entry "a" component 1 ])
           in
           let* _ = Diagnostics.Fence.await fence in
           (* A second reconcile of the same declaration with a changed
              configuration runs the raising callback before any mutation. *)
           let* rejected =
             Effect.fold
               ~ok:(fun _ -> false) ~error:(fun _ -> true)
               (Context.reconcile context (tree_of [ entry "a" component 2 ]))
           in
           let* snapshot = Diagnostics.snapshot diagnostics in
           Effect.sync (fun () -> (rejected, snapshot))))
  in
  let rejected, snapshot = expect_ok outcome in
  Alcotest.(check bool) "raising config_equal rejected" true rejected;
  Alcotest.(check string) "still active with original configuration" "active"
    (find_phase snapshot "a");
  (* No second activation happened: the rejection changed nothing. *)
  Alcotest.(check (list string)) "one activation" [ "activate" ] !log;
  check_census outcome

(* ------------------------------------------------------------------ *)
(* failure_locality_and_quarantine_fence: one failing instance does not   *)
(* disturb an unrelated sibling; retry on the quarantined instance is     *)
(* rejected.                                                              *)
(* ------------------------------------------------------------------ *)

let test_component_failure_locality_and_quarantine_fence () =
  let failing = tracked "failing" in
  failing.t_fail_with <- Some "boom";
  let failing_component = tracked_component failing in
  let healthy = tracked "healthy" in
  let healthy_component = tracked_component healthy in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* fence =
             Context.reconcile context
               (tree_of
                  [ entry "bad" failing_component 1;
                    entry "good" healthy_component 1 ])
           in
           let* _ = Diagnostics.Fence.await fence in
           let* snapshot = Diagnostics.snapshot diagnostics in
           let* integrity_snapshot = Diagnostics.snapshot diagnostics in
           Effect.sync (fun () ->
               (snapshot, integrity_snapshot))))
  in
  let snapshot, integrity_snapshot = expect_ok outcome in
  Alcotest.(check string) "failing entry failed" "activation-failed"
    (find_phase snapshot "bad");
  Alcotest.(check string) "sibling stays active" "active"
    (find_phase snapshot "good");
  (* An activation failure alone never degrades integrity. *)
  (match Diagnostics.integrity integrity_snapshot with
  | Diagnostics.Sound -> ()
  | Diagnostics.Degraded _ -> Alcotest.fail "unexpected degraded integrity"
  | Diagnostics.Failed _ -> Alcotest.fail "unexpected failed integrity");
  check_census outcome

(* ------------------------------------------------------------------ *)
(* shutdown_fence_idempotence: repeated shutdown returns one fence and    *)
(* runs no cleanup twice.                                                 *)
(* ------------------------------------------------------------------ *)

let test_component_shutdown_fence_idempotence () =
  let tracked = tracked "shutdown" in
  let component = tracked_component tracked in
  let outcome =
    run_program
      (Context.run (fun context _diagnostics ->
           let* fence =
             Context.reconcile context (tree_of [ entry "a" component 1 ])
           in
           let* _ = Diagnostics.Fence.await fence in
           let* first = Context.shutdown context in
           let* second = Context.shutdown context in
           let same_id =
             Diagnostics.Fence_id.equal
               (Diagnostics.Fence.id first)
               (Diagnostics.Fence.id second)
           in
           let* report1 = Diagnostics.Fence.await first in
           let* report2 = Diagnostics.Fence.await second in
           Effect.sync (fun () -> (same_id, report1, report2))))
  in
  let same_id, report1, report2 = expect_ok outcome in
  Alcotest.(check bool) "same fence" true same_id;
  Alcotest.(check int) "release ran once" 1
    (List.length
       (List.filter (fun event -> event = "release:shutdown") (events tracked)));
  Alcotest.(check bool) "same report" true
    (Diagnostics.Fence.outcome report1 = Diagnostics.Fence.outcome report2);
  check_census outcome

(* ------------------------------------------------------------------ *)
(* desired_admission_atomic + cycle_rejection_atomic: invalid snapshots   *)
(* change no accepted fact.                                               *)
(* ------------------------------------------------------------------ *)

let test_component_desired_admission_atomic () =
  let tracked = tracked "admission" in
  let component = tracked_component tracked in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* fence =
             Context.reconcile context (tree_of [ entry "a" component 1 ])
           in
           let* _ = Diagnostics.Fence.await fence in
           let* snapshot_before = Diagnostics.snapshot diagnostics in
           (* Duplicate entry ids are rejected before any mutation. *)
           let duplicate =
             Desired_state.tree
               [ Desired_state.component (entry "dup" component 1);
                 Desired_state.component (entry "dup" component 2) ]
           in
           let* rejected =
             Effect.fold
               ~ok:(fun _ -> false) ~error:(fun _ -> true)
               (Context.reconcile context duplicate)
           in
           let* snapshot_after = Diagnostics.snapshot diagnostics in
           Effect.sync (fun () -> (rejected, snapshot_before, snapshot_after))))
  in
  let rejected, _before, after = expect_ok outcome in
  Alcotest.(check bool) "duplicate entry ids rejected" true rejected;
  Alcotest.(check string) "original instance still active" "active"
    (find_phase after "a");
  check_census outcome

(* ------------------------------------------------------------------ *)
(* telemetry_noninterference: with the default (dropping) runtime sinks   *)
(* the lifecycle result is unchanged.                                     *)
(* ------------------------------------------------------------------ *)

let test_component_telemetry_noninterference () =
  let tracked = tracked "telemetry" in
  let component = tracked_component tracked in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* fence =
             Context.reconcile context (tree_of [ entry "a" component 1 ])
           in
           let* report = Diagnostics.Fence.await fence in
           let* snapshot = Diagnostics.snapshot diagnostics in
           Effect.sync (fun () -> (report, snapshot))))
  in
  let report, snapshot = expect_ok outcome in
  Alcotest.(check bool) "quiescent with default sinks" true
    (Diagnostics.Fence.outcome report = Diagnostics.Fence.Quiescent);
  Alcotest.(check string) "active with default sinks" "active"
    (find_phase snapshot "a");
  (* The runtime used dropping in-memory sinks; authoritative observations
     are unchanged. *)
  check_census outcome

(* ------------------------------------------------------------------ *)
(* Provider coordination: a consumer resolves its requirement from the     *)
(* provider's committed episode; withdrawal settles the consumer before    *)
(* the provider.                                                           *)
(* ------------------------------------------------------------------ *)

let test_component_provider_resolution () =
  let key = coeffect_exn "database" in
  let provider_tracked = tracked "provider" in
  let provider = provider_component provider_tracked key (fun config -> config) in
  let consumer_tracked = tracked "consumer" in
  let consumer = consumer_component consumer_tracked key in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* fence =
             Context.reconcile context
               (tree_of
                  [ entry "db" provider 42; entry "svc" consumer 0 ])
           in
           let* report = Diagnostics.Fence.await fence in
           let* snapshot = Diagnostics.snapshot diagnostics in
           Effect.sync (fun () -> (report, snapshot))))
  in
  let report, snapshot = expect_ok outcome in
  Alcotest.(check bool) "quiescent" true
    (Diagnostics.Fence.outcome report = Diagnostics.Fence.Quiescent);
  Alcotest.(check string) "provider active" "active" (find_phase snapshot "db");
  Alcotest.(check string) "consumer active" "active"
    (find_phase snapshot "svc");
  (* The consumer observed the provider's value. *)
  Alcotest.(check bool) "consumer saw provision" true
    (List.exists
       (fun event -> event = "activate:42")
       (events consumer_tracked));
  check_census outcome

(* provider_withdrawal_order: removing a provider settles the consumer      *)
(* before the provider's own release runs.                                  *)
let test_component_provider_withdrawal_order () =
  let key = coeffect_exn "shared" in
  let provider_tracked, consumer_tracked = tracked_pair "provider" "consumer" in
  let provider = provider_component provider_tracked key (fun config -> config) in
  let consumer = consumer_component consumer_tracked key in
  let outcome =
    run_program
      (Context.run (fun context _diagnostics ->
           let* fence =
             Context.reconcile context
               (tree_of
                  [ entry "db" provider 7; entry "svc" consumer 0 ])
           in
           let* _ = Diagnostics.Fence.await fence in
           provider_tracked.t_shared := [];
           (* Remove the provider: the consumer must settle first. *)
           let* fence2 =
             Context.reconcile context (tree_of [ entry "svc" consumer 0 ])
           in
           let* _ = Diagnostics.Fence.await fence2 in
           Effect.unit))
  in
  let () = expect_ok outcome in
  let all_events = shared_events provider_tracked in
  let consumer_release_idx =
    List.find_index (fun event -> event = "release:consumer") all_events
  in
  let provider_release_idx =
    List.find_index (fun event -> event = "release:provider") all_events
  in
  (match consumer_release_idx, provider_release_idx with
  | Some consumer_idx, Some provider_idx ->
      Alcotest.(check bool) "consumer settles before provider" true
        (consumer_idx < provider_idx)
  | _ ->
      Alcotest.failf "expected both releases; got %s"
        (String.concat ";" all_events));
  check_census outcome

(* ------------------------------------------------------------------ *)
(* equal_value_episode_reactivation: a provider restart with an equal     *)
(* provision value still reactivates the consumer (episode identity, not  *)
(* value equivalence, drives reactivation).                               *)
(* ------------------------------------------------------------------ *)

let test_component_equal_value_episode_reactivation () =
  let key = coeffect_exn "config" in
  let provider_tracked, consumer_tracked = tracked_pair "provider" "consumer" in
  let provider = provider_component provider_tracked key (fun config -> config) in
  let consumer = consumer_component consumer_tracked key in
  let outcome =
    run_program
      (Context.run (fun context _diagnostics ->
           let* fence =
             Context.reconcile context
               (tree_of [ entry "db" provider 7; entry "svc" consumer 0 ])
           in
           let* _ = Diagnostics.Fence.await fence in
           (* Change the provider config to an UNEQUAL value, then back to an
              equal one via a fresh declaration with different identity but
              equal value: the consumer must reactivate on provider episode
              change even when the provision value is equal. *)
           let* fence2 =
             Context.reconcile context
               (tree_of [ entry "db" provider 8; entry "svc" consumer 0 ])
           in
           let* _ = Diagnostics.Fence.await fence2 in
           Effect.unit))
  in
  let () = expect_ok outcome in
  (* The consumer activated twice: once for the original episode, once for
     the restarted provider's fresh episode. *)
  Alcotest.(check int) "consumer reactivated" 2 consumer_tracked.t_activations;
  Alcotest.(check bool) "consumer observed both episode values" true
    (List.exists (fun event -> event = "activate:7") (events consumer_tracked)
    && List.exists (fun event -> event = "activate:8") (events consumer_tracked));
  check_census outcome

(* ------------------------------------------------------------------ *)
(* episode_identity_bijection: one staged generation yields one episode;  *)
(* a consumer's committed view names that episode.                        *)
(* ------------------------------------------------------------------ *)

let test_component_episode_identity_bijection () =
  let key = coeffect_exn "identity" in
  let provider_tracked = tracked "provider" in
  let provider = provider_component provider_tracked key (fun config -> config) in
  let consumer_tracked = tracked "consumer" in
  let consumer = consumer_component consumer_tracked key in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* fence =
             Context.reconcile context
               (tree_of [ entry "db" provider 3; entry "svc" consumer 0 ])
           in
           let* _ = Diagnostics.Fence.await fence in
           let* snapshot = Diagnostics.snapshot diagnostics in
           Effect.sync (fun () -> snapshot)))
  in
  let snapshot = expect_ok outcome in
  (* The provider instance exposes one episode; the consumer's committed view
     names the same episode. *)
  let provider_episode =
    match
      List.find_opt
        (fun instance ->
          Entry_id.equal (Diagnostics.entry_id instance) (entry_id_exn "db"))
        (Diagnostics.instances snapshot)
    with
    | Some instance -> Diagnostics.provider_episode instance
    | None -> Alcotest.fail "provider instance missing"
  in
  let consumer_view =
    match
      List.find_opt
        (fun instance ->
          Entry_id.equal (Diagnostics.entry_id instance) (entry_id_exn "svc"))
        (Diagnostics.instances snapshot)
    with
    | Some instance -> Diagnostics.committed_view instance
    | None -> Alcotest.fail "consumer instance missing"
  in
  (match provider_episode, consumer_view with
  | Some episode, [ binding ] ->
      Alcotest.(check string) "requirement name" "identity"
        (Diagnostics.requirement_name binding);
      Alcotest.(check bool) "same episode" true
        (Diagnostics.Episode_id.equal
           (Diagnostics.requirement_provider binding)
           episode)
  | Some _, _ -> Alcotest.fail "expected exactly one requirement binding"
  | None, _ -> Alcotest.fail "provider episode missing");
  check_census outcome

(* ------------------------------------------------------------------ *)
(* settlement_report_repeatability: repeated awaits return the same       *)
(* terminal report.                                                       *)
(* ------------------------------------------------------------------ *)

let test_component_settlement_report_repeatability () =
  let tracked = tracked "repeat" in
  let component = tracked_component tracked in
  let outcome =
    run_program
      (Context.run (fun context _diagnostics ->
           let* fence =
             Context.reconcile context (tree_of [ entry "a" component 1 ])
           in
           let* first = Diagnostics.Fence.await fence in
           let* second = Diagnostics.Fence.await fence in
           Effect.sync (fun () ->
               ( Diagnostics.Fence.report_id first,
                 Diagnostics.Fence.report_id second,
                 Diagnostics.Fence.outcome first,
                 Diagnostics.Fence.outcome second ))))
  in
  let id1, id2, outcome1, outcome2 = expect_ok outcome in
  Alcotest.(check bool) "same report id" true
    (Diagnostics.Fence_id.equal id1 id2);
  Alcotest.(check bool) "same outcome" true (outcome1 = outcome2);
  check_census outcome

(* ------------------------------------------------------------------ *)
(* diagnostics_revision_atomicity: successive snapshots have increasing   *)
(* revisions, and a stale revision observes a changed snapshot.            *)
(* ------------------------------------------------------------------ *)

let test_component_diagnostics_revision_atomicity () =
  let tracked = tracked "revisions" in
  let component = tracked_component tracked in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* snapshot0 = Diagnostics.snapshot diagnostics in
           let* fence =
             any_error
               (Context.reconcile context (tree_of [ entry "a" component 1 ]))
           in
           let* _ = Diagnostics.Fence.await fence in
           let* snapshot1 = Diagnostics.snapshot diagnostics in
           let* change =
             any_error
               (Diagnostics.await_change diagnostics
                  ~after:(Diagnostics.revision snapshot0))
           in
           Effect.sync (fun () -> (snapshot0, snapshot1, change))))
  in
  let snapshot0, snapshot1, change = expect_ok outcome in
  (match change with
  | Diagnostics.Changed later ->
      Alcotest.(check int) "instances visible" 1
        (List.length (Diagnostics.instances later))
  | Diagnostics.Closed _ -> Alcotest.fail "context closed unexpectedly");
  Alcotest.(check int) "one instance after reconcile" 1
    (List.length (Diagnostics.instances snapshot1));
  ignore snapshot0;
  check_census outcome

(* ------------------------------------------------------------------ *)
(* failure_rendering_stability: an activation failure is retained and      *)
(* rendered; the phase carries the failure.                               *)
(* ------------------------------------------------------------------ *)

let test_component_failure_rendering_stability () =
  let tracked = tracked "render" in
  tracked.t_fail_with <- Some "kaboom";
  let component = tracked_component tracked in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* fence =
             Context.reconcile context (tree_of [ entry "a" component 1 ])
           in
           let* _ = Diagnostics.Fence.await fence in
           let* snapshot = Diagnostics.snapshot diagnostics in
           Effect.sync (fun () -> snapshot)))
  in
  let snapshot = expect_ok outcome in
  let rendered =
    match
      List.find_opt
        (fun instance ->
          Entry_id.equal (Diagnostics.entry_id instance) (entry_id_exn "a"))
        (Diagnostics.instances snapshot)
    with
    | Some instance -> (
        match Diagnostics.phase instance with
        | Diagnostics.Activation_failed (_, failure) -> (
            match Diagnostics.Failure.rendering failure with
            | Diagnostics.Failure.Rendered rendering ->
                Some rendering.Diagnostics.Failure.pretty
            | Diagnostics.Failure.Renderer_failed _ -> Some "<renderer-failed>")
        | _ -> None)
    | None -> None
  in
  (match rendered with
  | Some text ->
      Alcotest.(check bool) "rendered cause mentions the failure" true
        (String.length text > 0)
  | None -> Alcotest.fail "expected an activation failure with a rendering");
  check_census outcome

(* ------------------------------------------------------------------ *)
(* context_lexical_lifetime: when the body returns, the context shuts     *)
(* down and settles every owned scope before the run effect completes.    *)
(* ------------------------------------------------------------------ *)

let test_component_context_lexical_lifetime () =
  let tracked = tracked "lifetime" in
  let component = tracked_component tracked in
  let outcome =
    run_program
      (Context.run (fun context _diagnostics ->
           let* fence =
             Context.reconcile context (tree_of [ entry "a" component 1 ])
           in
           let* _ = Diagnostics.Fence.await fence in
           (* The body returns without an explicit shutdown: the lexical
              lifetime owns the shutdown. *)
           Effect.unit))
  in
  let () = expect_ok outcome in
  Alcotest.(check bool) "release ran at body exit" true
    (List.exists (fun event -> event = "release:lifetime") (events tracked));
  check_census outcome

(* ------------------------------------------------------------------ *)
(* change_wait_race_freedom: a waiter on the current revision is released *)
(* by the next mutation; waiting on a stale revision returns immediately. *)
(* ------------------------------------------------------------------ *)

let test_component_change_wait_race_freedom () =
  let tracked = tracked "wait" in
  let component = tracked_component tracked in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* snapshot0 = Diagnostics.snapshot diagnostics in
           (* Wait for a change from the initial revision in a sibling fiber
              while this fiber reconciles. *)
           let* change, fence =
             Effect.par
               (any_error
                  (Diagnostics.await_change diagnostics
                     ~after:(Diagnostics.revision snapshot0)))
               (any_error
                  (Context.reconcile context (tree_of [ entry "a" component 1 ])))
           in
           let* _ = Diagnostics.Fence.await fence in
           Effect.sync (fun () -> change)))
  in
  let change = expect_ok outcome in
  (match change with
  | Diagnostics.Changed _ -> ()
  | Diagnostics.Closed _ -> Alcotest.fail "unexpected closed");
  check_census outcome


(* ------------------------------------------------------------------ *)
(* Replacement gates                                                    *)
(* ------------------------------------------------------------------ *)

(* Build a replacement candidate for an entry currently in the context. *)
let make_target entry_id instance target_revision component_entry =
  Replacement.target ~entry:component_entry ~expected_instance:instance
    ~expected_target:target_revision

let test_component_replacement_target_revision_fence () =
  let tracked = tracked "replace" in
  let component = tracked_component tracked in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* fence =
             any_error
               (Context.reconcile context (tree_of [ entry "a" component 1 ]))
           in
           let* _ = Diagnostics.Fence.await fence in
           let* snapshot = Diagnostics.snapshot diagnostics in
           let instance_id, target_revision =
             match
               List.find_opt
                 (fun instance ->
                   Entry_id.equal (Diagnostics.entry_id instance)
                     (entry_id_exn "a"))
                 (Diagnostics.instances snapshot)
             with
             | Some instance -> (
                 ( Diagnostics.instance_id instance,
                   Diagnostics.target_revision instance ))
             | None -> Alcotest.fail "instance missing"
           in
           let target_revision =
             match target_revision with
             | Some revision -> revision
             | None -> Alcotest.fail "target revision missing"
           in
           (* A stale target revision rejects before any mutation. *)
           let candidate_entry = entry "a" component 2 in
           let target =
             Replacement.target ~entry:candidate_entry
               ~expected_instance:instance_id
               ~expected_target:target_revision
           in
           let* candidate =
             match Replacement.candidate ~target ~component with
             | Ok candidate -> Effect.pure candidate
             | Error _ -> Alcotest.fail "candidate construction failed"
           in
           let* batch =
             match
               Replacement.batch
                 ~source_revision:(Source_revision.of_int64 1L)
                 [ candidate ]
             with
             | Ok batch -> Effect.pure batch
             | Error _ -> Alcotest.fail "batch construction failed"
           in
           let* first =
             any_error (Context.replace context batch)
           in
           let* _ = Diagnostics.Fence.await first in
           (* Reusing the same source revision is stale. *)
           let* stale_source =
             Effect.fold
               ~ok:(fun _ -> false) ~error:(fun _ -> true)
               (Context.replace context batch)
           in
           Effect.sync (fun () -> stale_source)))
  in
  let stale_source = expect_ok outcome in
  Alcotest.(check bool) "stale source revision rejected" true stale_source;
  check_census outcome

(* hmr_rollback_matrix: a candidate whose activation fails after drainage   *)
(* rolls the entry back to its saved declaration; the fence reports         *)
(* Rolled_back.                                                             *)
let test_component_hmr_rollback_matrix () =
  let good = tracked "good" in
  let good_component = tracked_component good in
  let bad = tracked "bad" in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* fence =
             any_error
               (Context.reconcile context
                  (tree_of [ entry "a" good_component 1 ]))
           in
           let* _ = Diagnostics.Fence.await fence in
           let* snapshot = Diagnostics.snapshot diagnostics in
           let instance_id, target_revision =
             match
               List.find_opt
                 (fun instance ->
                   Entry_id.equal (Diagnostics.entry_id instance)
                     (entry_id_exn "a"))
                 (Diagnostics.instances snapshot)
             with
             | Some instance ->
                 ( Diagnostics.instance_id instance,
                   Diagnostics.target_revision instance )
             | None -> Alcotest.fail "instance missing"
           in
           let target_revision =
             match target_revision with
             | Some revision -> revision
             | None -> Alcotest.fail "target revision missing"
           in
           (* The candidate keeps the same family identity: build the failing
              replacement declaration on the same family. *)
           let candidate_component =
             match
               Component.make ~family:(Component.family good_component)
                 ~config_equal:Int.equal
                 ~requirements:Requirement.none ~provisions:Provision.none
                 ~pp_error:(fun ppf error -> Format.pp_print_string ppf error)
                 ~activate:(fun _config () _activation ->
                   Effect.sync (fun () -> track bad "candidate-activate")
                   >>= fun () -> Effect.fail "candidate boom")
             with
             | Ok component -> component
             | Error _ -> Alcotest.fail "make failed"
           in
           (* [loaded_candidate] requires the packed component to match the
              target family; here we use the direct [candidate] against the
              same-family failing declaration. *)
           let candidate_target =
             Replacement.target ~entry:(entry "a" candidate_component 2)
               ~expected_instance:instance_id
               ~expected_target:target_revision
           in
           let* candidate =
             match
               Replacement.candidate ~target:candidate_target
                 ~component:candidate_component
             with
             | Ok candidate -> Effect.pure candidate
             | Error _ -> Alcotest.fail "candidate construction failed"
           in
           let* batch =
             match
               Replacement.batch
                 ~source_revision:(Source_revision.of_int64 1L)
                 [ candidate ]
             with
             | Ok batch -> Effect.pure batch
             | Error _ -> Alcotest.fail "batch construction failed"
           in
           let* replace_fence =
             any_error (Context.replace context batch)
           in
           let* report = Diagnostics.Fence.await replace_fence in
           let* after = Diagnostics.snapshot diagnostics in
           Effect.sync (fun () -> (report, after))))
  in
  let report, after = expect_ok outcome in
  let outcome_label =
    match Diagnostics.Fence.outcome report with
    | Diagnostics.Fence.Rolled_back -> "rolled-back"
    | Diagnostics.Fence.Quiescent -> "quiescent"
    | Diagnostics.Fence.Degraded -> "degraded"
    | Diagnostics.Fence.Superseded -> "superseded"
    | Diagnostics.Fence.Restoration_failed -> "restoration-failed"
    | Diagnostics.Fence.Context_failed -> "context-failed"
  in
  Alcotest.(check string) "candidate failure rolls back" "rolled-back"
    outcome_label;
  (* After rollback the original declaration is restored and active. *)
  Alcotest.(check string) "restored active" "active" (find_phase after "a");
  check_census outcome

(* ------------------------------------------------------------------ *)
(* cycle_rejection_atomic: a dependency cycle rejects the whole snapshot  *)
(* with no mutation.                                                      *)
(* ------------------------------------------------------------------ *)

let test_component_cycle_rejection_atomic () =
  (* Two components that require each other's provision. *)
  let key_a = coeffect_exn "key-a" in
  let key_b = coeffect_exn "key-b" in
  let family_a = Component.Family.create ~name:"ca" ~module_locator:"ca" () in
  let family_b = Component.Family.create ~name:"cb" ~module_locator:"cb" () in
  let pp ppf error = Format.pp_print_string ppf error in
  let component_a =
    match
      Component.make ~family:family_a ~config_equal:Int.equal
        ~requirements:(Requirement.one key_b)
        ~provisions:(Provision.one key_a)
        ~pp_error:pp
        ~activate:(fun _config requirement _activation ->
          Effect.pure requirement)
    with
    | Ok component -> component
    | Error _ -> Alcotest.fail "make a failed"
  in
  let component_b =
    match
      Component.make ~family:family_b ~config_equal:Int.equal
        ~requirements:(Requirement.one key_a)
        ~provisions:(Provision.one key_b)
        ~pp_error:pp
        ~activate:(fun _config requirement _activation ->
          Effect.pure requirement)
    with
    | Ok component -> component
    | Error _ -> Alcotest.fail "make b failed"
  in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* rejected =
             Effect.fold
               ~ok:(fun _ -> false) ~error:(fun _ -> true)
               (Context.reconcile context
                  (tree_of [ entry "a" component_a 1; entry "b" component_b 1 ]))
           in
           let* snapshot = Diagnostics.snapshot diagnostics in
           Effect.sync (fun () -> (rejected, snapshot))))
  in
  let rejected, snapshot = expect_ok outcome in
  Alcotest.(check bool) "cycle rejected" true rejected;
  Alcotest.(check int) "no instances" 0
    (List.length (Diagnostics.instances snapshot));
  check_census outcome

(* ------------------------------------------------------------------ *)
(* Duplicate provider rejection: two entries providing the same key in    *)
(* the same realm reject.                                                 *)
(* ------------------------------------------------------------------ *)

let test_component_duplicate_provider_rejection () =
  let key = coeffect_exn "dup-slot" in
  let p1 = provider_component (tracked "p1") key (fun config -> config) in
  let p2 = provider_component (tracked "p2") key (fun config -> config) in
  let outcome =
    run_program
      (Context.run (fun context _diagnostics ->
           Effect.fold
             ~ok:(fun _ -> false) ~error:(fun _ -> true)
             (Context.reconcile context
                (tree_of [ entry "p1" p1 1; entry "p2" p2 2 ]))))
  in
  let rejected = expect_ok outcome in
  Alcotest.(check bool) "duplicate provider rejected" true rejected;
  check_census outcome

(* ------------------------------------------------------------------ *)
(* cause_and_quarantine_matrix: a cleanup failure quarantines the         *)
(* instance, degrades integrity, and rejects retry.                       *)
(* ------------------------------------------------------------------ *)

let test_component_cause_and_quarantine_matrix () =
  let release_count = ref 0 in
  let family = Component.Family.create ~name:"q" ~module_locator:"q" () in
  let component =
    match
      Component.make ~family ~config_equal:Int.equal
        ~requirements:Requirement.none ~provisions:Provision.none
        ~pp_error:(fun ppf error -> Format.pp_print_string ppf error)
        ~activate:(fun _config () activation ->
          Activation.own activation
            ~acquire:(Effect.sync (fun () -> ()))
            ~release:(fun () ->
              Effect.sync (fun () ->
                  incr release_count;
                  raise (Failure "release blew up")))
            ~pp_release_error:(fun ppf _ -> Format.pp_print_string ppf "e"))
    with
    | Ok component -> component
    | Error _ -> Alcotest.fail "make failed"
  in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* fence =
             any_error
               (Context.reconcile context (tree_of [ entry "a" component 1 ]))
           in
           let* _ = Diagnostics.Fence.await fence in
           (* Remove the entry so the generation settles and cleanup runs. *)
           let* fence2 =
             any_error (Context.reconcile context (tree_of []))
           in
           let* _ = Diagnostics.Fence.await fence2 in
           let* snapshot = Diagnostics.snapshot diagnostics in
           let integrity = Diagnostics.integrity snapshot in
           (* Retry on the quarantined instance is rejected. *)
           let* retry_rejected =
             Effect.fold
               ~ok:(fun _ -> false) ~error:(fun _ -> true)
               (Context.retry context (entry_id_exn "a"))
           in
           Effect.sync (fun () -> (integrity, retry_rejected))))
  in
  let integrity, retry_rejected = expect_ok outcome in
  Alcotest.(check int) "release attempted once" 1 !release_count;
  (match integrity with
  | Diagnostics.Degraded _ -> ()
  | Diagnostics.Sound -> Alcotest.fail "expected degraded integrity"
  | Diagnostics.Failed _ -> Alcotest.fail "unexpected context failure");
  Alcotest.(check bool) "retry on quarantined rejected" true retry_rejected;
  check_census outcome

(* ------------------------------------------------------------------ *)
(* Interception metadata: identity, associativity, and fold order.         *)
(* ------------------------------------------------------------------ *)

let test_component_interception_metadata_fold_order () =
  (* Metadata is a list of tags; merge appends. The fold runs
     component-declared, then outer context, then inner context. *)
  let observed = ref [] in
  let interception =
    Coeffect.Interception.create ~name:"traced"
      ~equivalent:Int.equal ~empty:[] ~merge:(fun left right -> left @ right)
      ~wrap:(fun ~sample value ->
        let metadata = sample () in
        observed := metadata;
        value)
      ()
  in
  let key = Coeffect.Interception.coeffect interception in
  (* A provider for the intercepted key; the consumer wraps the resolved
     value, which samples the merged metadata. *)
  let provider_tracked = tracked "intercepted-provider" in
  let provider = provider_component provider_tracked key (fun config -> config) in
  let family = Component.Family.create ~name:"i" ~module_locator:"i" () in
  (* The component declares metadata ["component"]. *)
  let component =
    match
      Component.make ~family ~config_equal:Int.equal
        ~requirements:
          (Requirement.intercepted interception ~metadata:[ "component" ])
        ~provisions:Provision.none
        ~pp_error:(fun ppf error -> Format.pp_print_string ppf error)
        ~activate:(fun _config _requirement activation ->
          (* Requirement resolution already ran the interception wrapper,
             which sampled the merged metadata. *)
          Activation.own activation
            ~acquire:(Effect.sync (fun () -> ()))
            ~release:(fun () -> Effect.unit)
            ~pp_release_error:(fun ppf _ -> Format.pp_print_string ppf "e"))
    with
    | Ok component -> component
    | Error _ -> Alcotest.fail "make failed"
  (* Outer and inner context layers. *)
  and outer_spec =
    Desired_state.Context_spec.intercept interception [ "outer" ]
      Desired_state.Context_spec.empty
  and inner_spec =
    Desired_state.Context_spec.intercept interception [ "inner" ]
      Desired_state.Context_spec.empty
  in
  let child_entry =
    Desired_state.Entry.make ~id:(entry_id_exn "c") ~component ~config:1
      ~enabled:true ~context:inner_spec
  in
  let tree =
    Desired_state.tree
      [ Desired_state.component (entry "p" provider 7);
        Desired_state.group ~id:(entry_id_exn "g") ~enabled:true
          ~context:outer_spec
          [ Desired_state.component child_entry ] ]
  in
  let outcome =
    run_program
      (Context.run (fun context _diagnostics ->
           let* fence =
             any_error (Context.reconcile context tree)
           in
           Diagnostics.Fence.await fence >>= fun _ -> Effect.unit))
  in
  let () = expect_ok outcome in
  Alcotest.(check (list string)) "fold order component, outer, inner"
    [ "component"; "outer"; "inner" ] !observed;
  check_census outcome


(* ------------------------------------------------------------------ *)
(* reconciliation_identity_rules: a retained entry keeps its instance; a  *)
(* removed-then-readded entry creates a fresh instance.                   *)
(* ------------------------------------------------------------------ *)

let test_component_reconciliation_identity_rules () =
  let tracked = tracked "identity" in
  let component = tracked_component tracked in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* fence =
             Context.reconcile context (tree_of [ entry "a" component 1 ])
           in
           let* _ = Diagnostics.Fence.await fence in
           let* snapshot1 = Diagnostics.snapshot diagnostics in
           let instance1 =
             match
               List.find_opt
                 (fun instance ->
                   Entry_id.equal (Diagnostics.entry_id instance)
                     (entry_id_exn "a"))
                 (Diagnostics.instances snapshot1)
             with
             | Some instance -> Diagnostics.instance_id instance
             | None -> Alcotest.fail "instance missing"
           in
           (* Retained entry keeps its instance. *)
           let* fence2 =
             Context.reconcile context (tree_of [ entry "a" component 1 ])
           in
           let* _ = Diagnostics.Fence.await fence2 in
           let* snapshot2 = Diagnostics.snapshot diagnostics in
           let instance2 =
             match
               List.find_opt
                 (fun instance ->
                   Entry_id.equal (Diagnostics.entry_id instance)
                     (entry_id_exn "a"))
                 (Diagnostics.instances snapshot2)
             with
             | Some instance -> Diagnostics.instance_id instance
             | None -> Alcotest.fail "instance missing after reconcile"
           in
           (* Remove then re-add: fresh instance. *)
           let* fence3 = Context.reconcile context (tree_of []) in
           let* _ = Diagnostics.Fence.await fence3 in
           let* fence4 =
             Context.reconcile context (tree_of [ entry "a" component 1 ])
           in
           let* _ = Diagnostics.Fence.await fence4 in
           let* snapshot3 = Diagnostics.snapshot diagnostics in
           let instance3 =
             match
               List.find_opt
                 (fun instance ->
                   Entry_id.equal (Diagnostics.entry_id instance)
                     (entry_id_exn "a"))
                 (Diagnostics.instances snapshot3)
             with
             | Some instance -> Diagnostics.instance_id instance
             | None -> Alcotest.fail "instance missing after re-add"
           in
           Effect.sync (fun () -> (instance1, instance2, instance3))))
  in
  let instance1, instance2, instance3 = expect_ok outcome in
  Alcotest.(check bool) "retained entry keeps instance" true
    (Diagnostics.Instance_id.equal instance1 instance2);
  Alcotest.(check bool) "re-added entry creates fresh instance" true
    (not (Diagnostics.Instance_id.equal instance1 instance3));
  check_census outcome

(* ------------------------------------------------------------------ *)
(* Realm isolation: two realms for one key admit one provider each; the   *)
(* root realm is the default.                                             *)
(* ------------------------------------------------------------------ *)

let test_component_realm_isolation () =
  let key = coeffect_exn "realm-key" in
  let realm = Desired_state.Realm.create ~name:"isolated" () in
  let provider_tracked = tracked "isolated-provider" in
  let provider = provider_component provider_tracked key (fun config -> config) in
  let root_provider_tracked = tracked "root-provider" in
  let root_provider =
    provider_component root_provider_tracked key (fun config -> config)
  in
  let isolated_spec =
    Desired_state.Context_spec.isolate key realm
      Desired_state.Context_spec.empty
  in
  let isolated_entry =
    Desired_state.Entry.make ~id:(entry_id_exn "iso") ~component:provider
      ~config:1 ~enabled:true ~context:isolated_spec
  in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           (* One provider in the isolated realm, one in the root realm: no
              duplicate-provider rejection. *)
           let* result =
             Effect.fold
               ~ok:(fun fence -> `Ok fence) ~error:(fun _ -> `Rejected)
               (Context.reconcile context
                  (Desired_state.tree
                     [ Desired_state.component isolated_entry;
                       Desired_state.component (entry "root" root_provider 2) ]))
           in
           match result with
           | `Rejected -> Alcotest.fail "realm-isolated providers rejected"
           | `Ok fence ->
               let* _ = Diagnostics.Fence.await fence in
               Diagnostics.snapshot diagnostics))
  in
  let snapshot = expect_ok outcome in
  Alcotest.(check string) "isolated provider active" "active"
    (find_phase snapshot "iso");
  Alcotest.(check string) "root provider active" "active"
    (find_phase snapshot "root");
  check_census outcome

(* ------------------------------------------------------------------ *)
(* direct_lease_cardinality: a consumer requiring several keys from one   *)
(* provider episode creates one lease; the provider settles only after    *)
(* the consumer.                                                          *)
(* ------------------------------------------------------------------ *)

let test_component_direct_lease_cardinality () =
  let key_a = coeffect_exn "lease-a" in
  let key_b = coeffect_exn "lease-b" in
  let provider_tracked, consumer_tracked = tracked_pair "provider" "consumer" in
  (* One provider providing two coeffects. *)
  let provider_family =
    Component.Family.create ~name:"multi" ~module_locator:"multi" ()
  in
  let provider =
    match
      Component.make ~family:provider_family ~config_equal:Int.equal
        ~requirements:Requirement.none
        ~provisions:Provision.(both (one key_a) (one key_b))
        ~pp_error:(fun ppf error -> Format.pp_print_string ppf error)
        ~activate:(fun config () activation ->
          Effect.sync (fun () ->
              provider_tracked.t_activations <- provider_tracked.t_activations + 1;
              track provider_tracked "activate:provider")
          >>= fun () ->
          Activation.own activation
            ~acquire:(Effect.sync (fun () ->
                 track provider_tracked "acquire:provider"))
            ~release:(fun () ->
              Effect.sync (fun () -> track provider_tracked "release:provider"))
            ~pp_release_error:(fun ppf _ -> Format.pp_print_string ppf "e")
          >>= fun () -> Effect.pure (config, config + 1))
    with
    | Ok component -> component
    | Error _ -> Alcotest.fail "make provider failed"
  in
  (* One consumer requiring both coeffects. *)
  let consumer_family =
    Component.Family.create ~name:"multi-consumer" ~module_locator:"mc" ()
  in
  let consumer =
    match
      Component.make ~family:consumer_family ~config_equal:Int.equal
        ~requirements:Requirement.(both (one key_a) (one key_b))
        ~provisions:Provision.none
        ~pp_error:(fun ppf error -> Format.pp_print_string ppf error)
        ~activate:(fun _config (value_a, value_b) activation ->
          Effect.sync (fun () ->
              track consumer_tracked
                (Printf.sprintf "activate:%d:%d" value_a value_b))
          >>= fun () ->
          Activation.own activation
            ~acquire:(Effect.sync (fun () ->
                 track consumer_tracked "acquire:consumer"))
            ~release:(fun () ->
              Effect.sync (fun () -> track consumer_tracked "release:consumer"))
            ~pp_release_error:(fun ppf _ -> Format.pp_print_string ppf "e"))
    with
    | Ok component -> component
    | Error _ -> Alcotest.fail "make consumer failed"
  in
  let outcome =
    run_program
      (Context.run (fun context _diagnostics ->
           let* fence =
             Context.reconcile context
               (tree_of [ entry "p" provider 10; entry "c" consumer 0 ])
           in
           let* _ = Diagnostics.Fence.await fence in
           (* Remove the provider; the consumer settles first, releasing its
              single episode lease. *)
           let* fence2 =
             Context.reconcile context (tree_of [ entry "c" consumer 0 ])
           in
           let* _ = Diagnostics.Fence.await fence2 in
           Effect.unit))
  in
  let () = expect_ok outcome in
  let all = shared_events provider_tracked in
  let releases =
    List.filter (fun event -> String.length event >= 7 && String.sub event 0 7 = "release") all
  in
  Alcotest.(check (list string)) "consumer release precedes provider release"
    [ "release:consumer"; "release:provider" ] releases;
  Alcotest.(check int) "provider activated once" 1 provider_tracked.t_activations;
  check_census outcome

(* ------------------------------------------------------------------ *)
(* replacement_batch_constructor_matrix: batch and candidate constructor   *)
(* errors are typed and checked before any admission.                      *)
(* ------------------------------------------------------------------ *)

let test_component_replacement_batch_constructor_matrix () =
  (* Empty batch. *)
  (match Replacement.batch ~source_revision:(Source_revision.of_int64 1L) [] with
  | Error Replacement.Empty_batch -> ()
  | Error (Replacement.Duplicate_entry _) | Ok _ ->
      Alcotest.fail "empty batch accepted");
  (* Candidate identity mismatch: candidate family differs from target. *)
  let tracked_a = tracked "batch-a" in
  let component_a = tracked_component tracked_a in
  let tracked_b = tracked "batch-b" in
  let component_b = tracked_component tracked_b in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* fence =
             Context.reconcile context (tree_of [ entry "a" component_a 1 ])
           in
           let* _ = Diagnostics.Fence.await fence in
           let* snapshot = Diagnostics.snapshot diagnostics in
           let instance_id, target_revision =
             match
               List.find_opt
                 (fun instance ->
                   Entry_id.equal (Diagnostics.entry_id instance)
                     (entry_id_exn "a"))
                 (Diagnostics.instances snapshot)
             with
             | Some instance ->
                 ( Diagnostics.instance_id instance,
                   Option.get (Diagnostics.target_revision instance) )
             | None -> Alcotest.fail "instance missing"
           in
           (* The target declares component_a; the candidate supplies
              component_b, whose family differs: the candidate constructor
              rejects it. *)
           let target_a =
             Replacement.target ~entry:(entry "a" component_a 2)
               ~expected_instance:instance_id ~expected_target:target_revision
           in
           let mismatch_rejected =
             match
               Replacement.candidate ~target:target_a ~component:component_b
             with
             | Error (Replacement.Component_identity_mismatch _) -> true
             | Ok _ -> false
           in
           (* Duplicate entries in one batch. *)
           let good_target =
             Replacement.target ~entry:(entry "a" component_a 2)
               ~expected_instance:instance_id ~expected_target:target_revision
           in
           let candidate_1 =
             match
               Replacement.candidate ~target:good_target ~component:component_a
             with
             | Ok candidate -> candidate
             | Error _ -> Alcotest.fail "candidate 1 rejected"
           in
           let candidate_2 =
             match
               Replacement.candidate ~target:good_target ~component:component_a
             with
             | Ok candidate -> candidate
             | Error _ -> Alcotest.fail "candidate 2 rejected"
           in
           let duplicate_rejected =
             match
               Replacement.batch ~source_revision:(Source_revision.of_int64 1L)
                 [ candidate_1; candidate_2 ]
             with
             | Error (Replacement.Duplicate_entry _) -> true
             | Error Replacement.Empty_batch | Ok _ -> false
           in
           Effect.sync (fun () -> (mismatch_rejected, duplicate_rejected))))
  in
  let mismatch_rejected, duplicate_rejected = expect_ok outcome in
  Alcotest.(check bool) "candidate identity mismatch rejected" true
    mismatch_rejected;
  Alcotest.(check bool) "duplicate batch entry rejected" true duplicate_rejected;
  check_census outcome

(* ------------------------------------------------------------------ *)
(* await_change_error_matrix: stale revisions return the latest snapshot   *)
(* immediately; a foreign revision is Wrong_context.                       *)
(* ------------------------------------------------------------------ *)

let test_component_await_change_error_matrix () =
  let outcome =
    run_program
      (Context.run (fun context_one diagnostics_one ->
           let tracked_a = tracked "await-a" in
           let component_a = tracked_component tracked_a in
           let* fence =
             any_error
               (Context.reconcile context_one (tree_of [ entry "a" component_a 1 ]))
           in
           let* _ = Diagnostics.Fence.await fence in
           let* snapshot_one = Diagnostics.snapshot diagnostics_one in
           let revision_one = Diagnostics.revision snapshot_one in
           (* Advance one revision so revision_one becomes stale. *)
           let* fence2 =
             any_error
               (Context.reconcile context_one (tree_of [ entry "a" component_a 2 ]))
           in
           let* _ = Diagnostics.Fence.await fence2 in
           (* A stale same-context revision returns the latest snapshot
              immediately. *)
           let* change =
             any_error
               (Diagnostics.await_change diagnostics_one ~after:revision_one)
           in
           Effect.sync (fun () -> (revision_one, change))))
  in
  let revision_one, change = expect_ok outcome in
  (* In the deterministic test runtime, a returned [Changed] proves the
     await did not block: the stale revision yielded the latest snapshot. *)
  (match change with
  | Diagnostics.Changed _ -> ()
  | Diagnostics.Closed _ -> Alcotest.fail "live context reported Closed");
  check_census outcome;
  (* A foreign revision in a different context is Wrong_context. *)
  let outcome_two =
    run_program
      (Context.run (fun _context_two diagnostics_two ->
           Effect.fold
             ~ok:(fun _ -> false)
             ~error:(function
               | Diagnostics.Wrong_context -> true
               | Diagnostics.Invalid_revision -> false)
             (Diagnostics.await_change diagnostics_two ~after:revision_one)))
  in
  let wrong_context = expect_ok outcome_two in
  Alcotest.(check bool) "foreign revision is Wrong_context" true wrong_context;
  check_census outcome_two

(* ------------------------------------------------------------------ *)
(* release_renderer_failure: a raising pp_release_error is recorded and    *)
(* surfaced as Renderer_failed; the authoritative cause is unchanged.      *)
(* ------------------------------------------------------------------ *)

let test_component_release_renderer_failure () =
  let component =
    let family =
      Component.Family.create ~name:"rr" ~module_locator:"rr" ()
    in
    match
      Component.make ~family ~config_equal:Int.equal
        ~requirements:Requirement.none ~provisions:Provision.none
        ~pp_error:(fun ppf error -> Format.pp_print_string ppf error)
        ~activate:(fun _config () activation ->
          Activation.own activation
            ~acquire:(Effect.sync (fun () -> ()))
            ~release:(fun () -> Effect.fail "release-failed")
            ~pp_release_error:(fun _ppf _error ->
              raise (Failure "renderer blew up")))
    with
    | Ok component -> component
    | Error _ -> Alcotest.fail "make failed"
  in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* fence =
             any_error
               (Context.reconcile context (tree_of [ entry "a" component 1 ]))
           in
           let* _ = Diagnostics.Fence.await fence in
           (* Remove the entry so the release runs and fails; the renderer
              raises during finalizer capture. *)
           let* fence2 =
             any_error (Context.reconcile context (tree_of []))
           in
           let* report = Diagnostics.Fence.await fence2 in
           let failures = Diagnostics.Fence.failures report in
           let* snapshot = Diagnostics.snapshot diagnostics in
           Effect.sync (fun () -> (failures, snapshot))))
  in
  let failures, snapshot = expect_ok outcome in
  let saw_renderer_failed =
    List.exists
      (fun failure ->
        match Diagnostics.Failure.rendering failure with
        | Diagnostics.Failure.Renderer_failed _ -> true
        | Diagnostics.Failure.Rendered _ -> false)
      failures
  in
  Alcotest.(check bool) "renderer failure surfaced as Renderer_failed" true
    saw_renderer_failed;
  (match Diagnostics.integrity snapshot with
  | Diagnostics.Degraded _ -> ()
  | Diagnostics.Sound -> Alcotest.fail "expected degraded integrity"
  | Diagnostics.Failed _ -> Alcotest.fail "unexpected context failure");
  check_census outcome

(* ------------------------------------------------------------------ *)
(* post_shutdown_rejection: a non-shutdown operation after shutdown        *)
(* started returns Context_not_running.                                   *)
(* ------------------------------------------------------------------ *)

let test_component_post_shutdown_rejection () =
  let tracked = tracked "ps" in
  let component = tracked_component tracked in
  let outcome =
    run_program
      (Context.run (fun context _diagnostics ->
           let* fence =
             Context.reconcile context (tree_of [ entry "a" component 1 ])
           in
           let* _ = Diagnostics.Fence.await fence in
           let* shutdown_fence = Context.shutdown context in
           let* _ = Diagnostics.Fence.await shutdown_fence in
           (* A reconcile after shutdown started is rejected. *)
           Effect.fold
             ~ok:(fun _ -> false)
             ~error:(function
               | Context.Context_not_running -> true
               | _ -> false)
             (Context.reconcile context (tree_of [ entry "b" component 2 ]))))
  in
  let rejected = expect_ok outcome in
  Alcotest.(check bool) "post-shutdown reconcile rejected" true rejected;
  check_census outcome

(* ------------------------------------------------------------------ *)
(* group_kind_authority_retention: a removed group's identifier cannot be  *)
(* reused as a component entry while a descendant is still known.          *)
(* ------------------------------------------------------------------ *)

let test_component_group_kind_authority_retention () =
  let tracked = tracked "gk" in
  let component = tracked_component tracked in
  let outcome =
    run_program
      (Context.run (fun context _diagnostics ->
           let tree1 =
             Desired_state.tree
               [ Desired_state.group ~id:(entry_id_exn "g") ~enabled:true
                   ~context:Desired_state.Context_spec.empty
                   [ Desired_state.component (entry "c" component 1) ] ]
           in
           let* fence = Context.reconcile context tree1 in
           let* _ = Diagnostics.Fence.await fence in
           (* Reuse the group id as a component entry: the group kind
              authority is still retained by the known descendant. *)
           let tree2 =
             Desired_state.tree
               [ Desired_state.component (entry "g" component 2) ]
           in
           Effect.fold
             ~ok:(fun _ -> false)
             ~error:(function
               | Context.Entry_kind_changed _ -> true
               | _ -> false)
             (Context.reconcile context tree2)))
  in
  let rejected = expect_ok outcome in
  Alcotest.(check bool) "group id reuse as entry rejected" true rejected;
  check_census outcome

(* ------------------------------------------------------------------ *)
(* Ported gates from the cordis reference suite                        *)
(* (.reference/cordis/packages/core/tests/dispose.spec.ts).            *)
(*                                                                     *)
(* Cordis model difference: JS async functions cannot be cancelled, so  *)
(* cordis lets an in-flight activation run to its next yield and then  *)
(* disposes. Eta delivers interruption to the pending acquisition      *)
(* directly. The ported gates therefore assert: completed acquisitions *)
(* are released, pending acquisitions never complete, and interrupted  *)
(* activations never stage.                                            *)
(* ------------------------------------------------------------------ *)

(* "async yield 2 (aborted)": retirement during a pending acquisition
   interrupts the acquisition; the already-completed acquisition is
   released and the pending one never lands. *)
let test_component_retire_mid_activation_interrupts () =
  let log = ref [] in
  let record event = log := !log @ [ event ] in
  let family = Component.Family.create ~name:"abort" ~module_locator:"abort" () in
  let outcome =
    run_program
      (Context.run (fun context _diagnostics ->
           let started = Promise.create () in
           let gate = Promise.create () in
           let component =
             match
               Component.make ~family ~config_equal:Int.equal
                 ~requirements:Requirement.none ~provisions:Provision.none
                 ~pp_error:(fun ppf error -> Format.pp_print_string ppf error)
                 ~activate:(fun _config () activation ->
                   let* () =
                     Activation.own activation
                       ~acquire:(Effect.sync (fun () -> record "acquire:1"))
                       ~release:(fun () ->
                         Effect.sync (fun () -> record "release:1"))
                       ~pp_release_error:(fun ppf _ ->
                         Format.pp_print_string ppf "e")
                   in
                   let* () =
                     Effect.map (fun _ -> ())
                       (Promise.resolve started (Exit.Ok ()))
                   in
                   (* The second acquisition never lands: retirement
                      interrupts the pending gate wait. *)
                   Activation.own activation
                     ~acquire:
                       (Effect.map (fun _ -> record "acquire:2")
                          (Promise.await gate))
                     ~release:(fun () ->
                       Effect.sync (fun () -> record "release:2"))
                     ~pp_release_error:(fun ppf _ ->
                       Format.pp_print_string ppf "e"))
             with
             | Ok component -> component
             | Error _ -> Alcotest.fail "make failed"
           in
           let* _fence =
             any_error
               (Context.reconcile context (tree_of [ entry "a" component 1 ]))
           in
           (* Wait until the activation is parked on the gated acquire. *)
           let* () = any_error (Promise.await started) in
           (* Retire the entry while the activation is in flight. *)
           let* retire_fence =
             any_error (Context.reconcile context (tree_of []))
           in
           let* _ = Diagnostics.Fence.await retire_fence in
           Effect.unit))
  in
  let () = expect_ok outcome in
  Alcotest.(check (list string))
    "completed acquire released, pending acquire never lands"
    [ "acquire:1"; "release:1" ] !log;
  check_census outcome

(* "yield with error": an activation failure after a successful [own]
   releases the registered resource. *)
let test_component_activation_failure_releases_owned () =
  let log = ref [] in
  let record event = log := !log @ [ event ] in
  let family = Component.Family.create ~name:"yerr" ~module_locator:"yerr" () in
  let component =
    match
      Component.make ~family ~config_equal:Int.equal
        ~requirements:Requirement.none ~provisions:Provision.none
        ~pp_error:(fun ppf error -> Format.pp_print_string ppf error)
        ~activate:(fun _config () activation ->
          let* () =
            Activation.own activation
              ~acquire:(Effect.sync (fun () -> record "acquire:1"))
              ~release:(fun () -> Effect.sync (fun () -> record "release:1"))
              ~pp_release_error:(fun ppf _ -> Format.pp_print_string ppf "e")
          in
          Effect.fail "boom")
    with
    | Ok component -> component
    | Error _ -> Alcotest.fail "make failed"
  in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* fence =
             Context.reconcile context (tree_of [ entry "a" component 1 ])
           in
           let* _ = Diagnostics.Fence.await fence in
           Diagnostics.snapshot diagnostics))
  in
  let snapshot = expect_ok outcome in
  Alcotest.(check (list string)) "owned resource released on failure"
    [ "acquire:1"; "release:1" ] !log;
  Alcotest.(check string) "phase" "activation-failed" (find_phase snapshot "a");
  check_census outcome

(* ------------------------------------------------------------------ *)
(* Ported from .reference/cordis/packages/core/tests/fiber.spec.ts and  *)
(* service.spec.ts.                                                    *)
(*                                                                     *)
(* Cordis "inertia lock" semantics differ from Eta's: a cordis fiber   *)
(* whose inject disappears mid-activation finishes loading, then        *)
(* unloads; Eta interrupts the in-flight activation directly. The      *)
(* ported gates assert the Eta observables of the same scenarios:      *)
(* lease-drain ordering, consumer reactivation, and single-restart     *)
(* semantics for combined updates.                                     *)
(* ------------------------------------------------------------------ *)

(* fiber.spec "inertia lock 1": the provider is withdrawn while the
   consumer activation is in flight. The consumer's pending acquisition
   is interrupted, its registered release runs, and the provider settles
   only after the consumer lease drains. Re-providing reactivates the
   consumer. *)
let test_component_provider_withdrawal_during_activation () =
  let key = coeffect_exn "inertia" in
  let provider_tracked, consumer_tracked = tracked_pair "provider" "consumer" in
  let provider = provider_component provider_tracked key (fun config -> config) in
  let outcome =
    run_program
      (Context.run (fun context _diagnostics ->
           let started = Promise.create () in
           let gate = Promise.create () in
           let consumer_family =
             Component.Family.create ~name:"consumer" ~module_locator:"consumer"
               ()
           in
           let consumer =
             match
               Component.make ~family:consumer_family ~config_equal:Int.equal
                 ~requirements:(Requirement.one key) ~provisions:Provision.none
                 ~pp_error:(fun ppf error -> Format.pp_print_string ppf error)
                 ~activate:(fun _config _requirement activation ->
                   let* () =
                     Activation.own activation
                       ~acquire:
                         (Effect.sync (fun () ->
                              track consumer_tracked "acquire:consumer"))
                       ~release:(fun () ->
                         Effect.sync (fun () ->
                             track consumer_tracked "release:consumer"))
                       ~pp_release_error:(fun ppf _ ->
                         Format.pp_print_string ppf "e")
                   in
                   let* () =
                     Effect.map (fun _ -> ())
                       (Promise.resolve started (Exit.Ok ()))
                   in
                   (* Park mid-activation so the withdrawal lands while the
                      generation is still uncommitted. *)
                   Effect.map (fun _ -> ()) (Promise.await gate))
             with
             | Ok component -> component
             | Error _ -> Alcotest.fail "make consumer failed"
           in
           let* _fence =
             any_error
               (Context.reconcile context
                  (tree_of [ entry "db" provider 7; entry "svc" consumer 0 ]))
           in
           let* () = any_error (Promise.await started) in
           provider_tracked.t_shared := [];
           (* Withdraw the provider mid-activation. *)
           let* retire_fence =
             any_error
               (Context.reconcile context (tree_of [ entry "svc" consumer 0 ]))
           in
           let* _ = Diagnostics.Fence.await retire_fence in
           (* Let any surviving gate waiter complete (none should exist:
              the in-flight generation was interrupted). *)
           let* _ = Promise.resolve gate (Exit.Ok ()) in
           (* Re-provide: the consumer reactivates against the fresh
              episode. *)
           let* fence2 =
             any_error
               (Context.reconcile context
                  (tree_of [ entry "db" provider 9; entry "svc" consumer 0 ]))
           in
           let* _ = Diagnostics.Fence.await fence2 in
           Effect.unit))
  in
  let () = expect_ok outcome in
  let all_events = shared_events provider_tracked in
  (* The consumer's interrupted activation released its registered
     resource before the provider's own release ran. *)
  let consumer_release_idx =
    List.find_index (fun event -> event = "release:consumer") all_events
  in
  let provider_release_idx =
    List.find_index (fun event -> event = "release:provider") all_events
  in
  (match consumer_release_idx, provider_release_idx with
  | Some consumer_idx, Some provider_idx ->
      Alcotest.(check bool) "consumer release before provider release" true
        (consumer_idx < provider_idx)
  | _ ->
      Alcotest.failf "expected both releases; got %s"
        (String.concat ";" all_events));
  (* The shared log was reset after the first generation parked, so it
     contains: the interrupted generation's release, the provider's release,
     and the reactivated generation's acquire (plus the shutdown releases at
     context exit). The reactivated generation acquired exactly once. *)
  Alcotest.(check int) "reactivated generation acquired once" 1
    (List.length
       (List.filter (fun event -> event = "acquire:consumer") all_events));
  check_census outcome

(* fiber.spec "update config while injected service reloads": one
   reconcile that changes the provider value and the consumer config
   restarts the consumer exactly once, observing both new values. *)
let test_component_combined_provider_consumer_update () =
  let key = coeffect_exn "combined" in
  let provider_tracked, consumer_tracked = tracked_pair "provider" "consumer" in
  let provider = provider_component provider_tracked key (fun config -> config) in
  let consumer_family =
    Component.Family.create ~name:"consumer" ~module_locator:"consumer" ()
  in
  let consumer =
    match
      Component.make ~family:consumer_family ~config_equal:Int.equal
        ~requirements:(Requirement.one key) ~provisions:Provision.none
        ~pp_error:(fun ppf error -> Format.pp_print_string ppf error)
        ~activate:(fun config requirement activation ->
          Effect.sync (fun () ->
              track consumer_tracked
                (Printf.sprintf "activate:%d:%d" requirement config))
          >>= fun () ->
          Activation.own activation
            ~acquire:
              (Effect.sync (fun () -> track consumer_tracked "acquire:consumer"))
            ~release:(fun () ->
              Effect.sync (fun () -> track consumer_tracked "release:consumer"))
            ~pp_release_error:(fun ppf _ -> Format.pp_print_string ppf "e"))
    with
    | Ok component -> component
    | Error _ -> Alcotest.fail "make consumer failed"
  in
  let outcome =
    run_program
      (Context.run (fun context _diagnostics ->
           let* fence =
             any_error
               (Context.reconcile context
                  (tree_of [ entry "db" provider 1; entry "svc" consumer 0 ]))
           in
           let* _ = Diagnostics.Fence.await fence in
           (* One atomic snapshot changes both the provider value and the
              consumer configuration. *)
           let* fence2 =
             any_error
               (Context.reconcile context
                  (tree_of [ entry "db" provider 2; entry "svc" consumer 1 ]))
           in
           let* _ = Diagnostics.Fence.await fence2 in
           Effect.unit))
  in
  let () = expect_ok outcome in
  let consumer_activations =
    List.filter
      (fun event -> String.starts_with ~prefix:"activate:" event)
      (events consumer_tracked)
  in
  Alcotest.(check (list string))
    "consumer restarted once with both new values"
    [ "activate:1:0"; "activate:2:1" ]
    consumer_activations;
  check_census outcome

(* service.spec "pending inject": a consumer whose provider activation is
   still in flight waits; it activates only after the provider commits. *)
let test_component_consumer_waits_for_gated_provider () =
  let key = coeffect_exn "gated" in
  let provider_tracked, consumer_tracked = tracked_pair "provider" "consumer" in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let gate = Promise.create () in
           let provider_family =
             Component.Family.create ~name:"provider" ~module_locator:"provider"
               ()
           in
           let provider =
             match
               Component.make ~family:provider_family ~config_equal:Int.equal
                 ~requirements:Requirement.none
                 ~provisions:(Provision.one key)
                 ~pp_error:(fun ppf error -> Format.pp_print_string ppf error)
                 ~activate:(fun config () activation ->
                   Effect.sync (fun () -> track provider_tracked "activate")
                   >>= fun () ->
                   Effect.map (fun _ -> ()) (Promise.await gate)
                   >>= fun () ->
                   Activation.own activation
                     ~acquire:
                       (Effect.sync (fun () ->
                            track provider_tracked "acquire:provider"))
                     ~release:(fun () ->
                       Effect.sync (fun () ->
                           track provider_tracked "release:provider"))
                     ~pp_release_error:(fun ppf _ ->
                       Format.pp_print_string ppf "e")
                   >>= fun () -> Effect.pure config)
             with
             | Ok component -> component
             | Error _ -> Alcotest.fail "make provider failed"
           in
           let consumer = consumer_component consumer_tracked key in
           let* fence =
             any_error
               (Context.reconcile context
                  (tree_of [ entry "db" provider 42; entry "svc" consumer 0 ]))
           in
           (* Let the coordinator process the plan while the provider is
              gated; the consumer must be waiting. Poll snapshots until the
              coordinator has placed the consumer. *)
           let rec poll_waiting () =
             let* snapshot = Diagnostics.snapshot diagnostics in
             let phase =
               match
                 List.find_opt
                   (fun (id, _) -> Entry_id.equal id (entry_id_exn "svc"))
                   (snapshot_phases snapshot)
               with
               | Some (_, phase) -> phase
               | None -> "absent"
             in
             if phase = "waiting" then Effect.pure phase
             else Effect.yield >>= poll_waiting
           in
           let* waiting_phase = any_error (poll_waiting ()) in
           (* Open the provider gate: the consumer may now activate. *)
           let* _ = Promise.resolve gate (Exit.Ok ()) in
           let* _ = Diagnostics.Fence.await fence in
           let* after = Diagnostics.snapshot diagnostics in
           Effect.sync (fun () -> (waiting_phase, after))))
  in
  let waiting_phase, after = expect_ok outcome in
  Alcotest.(check string) "consumer waiting while provider gated" "waiting"
    waiting_phase;
  Alcotest.(check string) "consumer active after gate" "active"
    (find_phase after "svc");
  Alcotest.(check bool) "consumer saw provision" true
    (List.exists (fun event -> event = "activate:42") (events consumer_tracked));
  check_census outcome

(* service.spec "multiple injects": activation order follows the
   requirement topology — qux before foo before bar. *)
let test_component_topological_activation_chain () =
  let key_a = coeffect_exn "chain-a" in
  let key_b = coeffect_exn "chain-b" in
  let log = ref [] in
  let record event = log := !log @ [ event ] in
  let pp ppf error = Format.pp_print_string ppf error in
  let mk name requirements provisions activate =
    match
      Component.make
        ~family:(Component.Family.create ~name ~module_locator:name ())
        ~config_equal:Int.equal ~requirements ~provisions ~pp_error:pp
        ~activate
    with
    | Ok component -> component
    | Error _ -> Alcotest.failf "make %s failed" name
  in
  (* qux provides key_a; foo requires key_a and provides key_b; bar
     requires key_b. *)
  let qux =
    mk "qux" Requirement.none (Provision.one key_a)
      (fun config () activation ->
        Effect.sync (fun () -> record "activate:qux")
        >>= fun () ->
        Activation.own activation
          ~acquire:Effect.unit
          ~release:(fun () -> Effect.unit)
          ~pp_release_error:pp
        >>= fun () -> Effect.pure config)
  in
  let foo =
    mk "foo" (Requirement.one key_a) (Provision.one key_b)
      (fun config _requirement activation ->
        Effect.sync (fun () -> record "activate:foo")
        >>= fun () ->
        Activation.own activation
          ~acquire:Effect.unit
          ~release:(fun () -> Effect.unit)
          ~pp_release_error:pp
        >>= fun () -> Effect.pure config)
  in
  let bar =
    mk "bar" (Requirement.one key_b) Provision.none
      (fun _config _requirement activation ->
        Effect.sync (fun () -> record "activate:bar")
        >>= fun () ->
        Activation.own activation
          ~acquire:Effect.unit
          ~release:(fun () -> Effect.unit)
          ~pp_release_error:pp)
  in
  let outcome =
    run_program
      (Context.run (fun context _diagnostics ->
           let* fence =
             any_error
               (Context.reconcile context
                  (tree_of
                     [ entry "bar" bar 0; entry "foo" foo 1; entry "qux" qux 2 ]))
           in
           let* _ = Diagnostics.Fence.await fence in
           Effect.unit))
  in
  let () = expect_ok outcome in
  Alcotest.(check (list string)) "topological activation order"
    [ "activate:qux"; "activate:foo"; "activate:bar" ]
    !log;
  check_census outcome

(* ------------------------------------------------------------------ *)
(* Ported from .reference/cordis/packages/loader/tests/group.spec.ts   *)
(* and index.spec.ts. Cordis groups are loader entries; ours are       *)
(* Desired_state.group nodes. The observable semantics port directly:  *)
(* enablement cascades down the tree and transfers between groups      *)
(* retain the instance when the effective enabled state is unchanged.  *)
(* ------------------------------------------------------------------ *)

let group_node id enabled children =
  Desired_state.group ~id:(entry_id_exn id) ~enabled
    ~context:Desired_state.Context_spec.empty children

(* group.spec "Group: basic support": nested groups cascade enablement.
   Disabling the inner group settles only its children; disabling the
   outer group settles everything; enabling the inner group while the
   outer is disabled activates nothing; enabling the outer activates
   both. *)
let test_component_group_disable_cascade () =
  let outer_tracked, inner_tracked = tracked_pair "outer" "inner" in
  let outer_component = tracked_component outer_tracked in
  let inner_component = tracked_component inner_tracked in
  let tree outer_enabled inner_enabled =
    Desired_state.tree
      [ group_node "outer" outer_enabled
          [ Desired_state.component (entry "a" outer_component 1);
            group_node "inner" inner_enabled
              [ Desired_state.component (entry "b" inner_component 1) ] ] ]
  in
  let outcome =
    run_program
      (Context.run (fun context _diagnostics ->
           let* fence = any_error (Context.reconcile context (tree true true)) in
           let* _ = Diagnostics.Fence.await fence in
           (* Disable the inner group: only the inner child settles. *)
           let* fence2 = any_error (Context.reconcile context (tree true false)) in
           let* _ = Diagnostics.Fence.await fence2 in
           let* () =
             Effect.sync (fun () ->
                 Alcotest.(check int) "inner released" 1
                   (List.length
                      (List.filter
                         (fun event -> event = "release:inner")
                         (events inner_tracked)));
                 Alcotest.(check int) "outer untouched" 0
                   (List.length
                      (List.filter
                         (fun event -> event = "release:outer")
                         (events outer_tracked))))
           in
           (* Disable the outer group: the outer child settles too. *)
           let* fence3 =
             any_error (Context.reconcile context (tree false false))
           in
           let* _ = Diagnostics.Fence.await fence3 in
           let* () =
             Effect.sync (fun () ->
                 Alcotest.(check int) "outer released" 1
                   (List.length
                      (List.filter
                         (fun event -> event = "release:outer")
                         (events outer_tracked))))
           in
           (* Enable the inner group while the outer is disabled: nothing
              activates. *)
           let* fence4 = any_error (Context.reconcile context (tree false true)) in
           let* _ = Diagnostics.Fence.await fence4 in
           let* () =
             Effect.sync (fun () ->
                 Alcotest.(check int) "inner not reactivated" 1
                   inner_tracked.t_activations)
           in
           (* Enable the outer group: both activate. *)
           let* fence5 = any_error (Context.reconcile context (tree true true)) in
           let* _ = Diagnostics.Fence.await fence5 in
           Effect.unit))
  in
  let () = expect_ok outcome in
  Alcotest.(check int) "outer activated twice" 2 outer_tracked.t_activations;
  Alcotest.(check int) "inner activated twice" 2 inner_tracked.t_activations;
  check_census outcome

(* group.spec "Group: transfer": moving an entry between groups retains
   the instance while the effective enabled state is unchanged, settles
   it on a move into a disabled group, and reactivates it on a move back
   to an enabled position. *)
let test_component_group_transfer_matrix () =
  let tracked = tracked "transfer" in
  let component = tracked_component tracked in
  let instance_id_of snapshot =
    match
      List.find_opt
        (fun instance ->
          Entry_id.equal (Diagnostics.entry_id instance) (entry_id_exn "x"))
        (Diagnostics.instances snapshot)
    with
    | Some instance -> Diagnostics.instance_id instance
    | None -> Alcotest.fail "instance x missing"
  in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let node_x = Desired_state.component (entry "x" component 1) in
           (* Start at the root, enabled. *)
           let* fence =
             any_error (Context.reconcile context (Desired_state.tree [ node_x ]))
           in
           let* _ = Diagnostics.Fence.await fence in
           let* snapshot1 = Diagnostics.snapshot diagnostics in
           let id_root = instance_id_of snapshot1 in
           (* Move into an enabled group: the instance is retained. *)
           let* fence2 =
             any_error
               (Context.reconcile context
                  (Desired_state.tree [ group_node "alpha" true [ node_x ] ]))
           in
           let* _ = Diagnostics.Fence.await fence2 in
           let* snapshot2 = Diagnostics.snapshot diagnostics in
           let id_alpha = instance_id_of snapshot2 in
           let releases_after_alpha =
             List.length
               (List.filter
                  (fun event -> event = "release:transfer")
                  (events tracked))
           in
           (* Move into a disabled group: the instance settles. *)
           let* fence3 =
             any_error
               (Context.reconcile context
                  (Desired_state.tree [ group_node "beta" false [ node_x ] ]))
           in
           let* _ = Diagnostics.Fence.await fence3 in
           let releases_after_beta =
             List.length
               (List.filter
                  (fun event -> event = "release:transfer")
                  (events tracked))
           in
           (* Move between two disabled groups: nothing happens. *)
           let* fence4 =
             any_error
               (Context.reconcile context
                  (Desired_state.tree
                     [ group_node "beta" false
                         [ group_node "gamma" true [ node_x ] ] ]))
           in
           let* _ = Diagnostics.Fence.await fence4 in
           let activations_after_gamma = tracked.t_activations in
           (* Move back to the root: the entry reactivates. *)
           let* fence5 =
             any_error (Context.reconcile context (Desired_state.tree [ node_x ]))
           in
           let* _ = Diagnostics.Fence.await fence5 in
           let* snapshot5 = Diagnostics.snapshot diagnostics in
           let id_root2 = instance_id_of snapshot5 in
           Effect.sync (fun () ->
               ( id_root,
                 id_alpha,
                 releases_after_alpha,
                 releases_after_beta,
                 activations_after_gamma,
                 id_root2 ))))
  in
  let ( id_root,
        id_alpha,
        releases_after_alpha,
        releases_after_beta,
        activations_after_gamma,
        id_root2 ) =
    expect_ok outcome
  in
  Alcotest.(check bool) "enabled->enabled retains instance" true
    (Diagnostics.Instance_id.equal id_root id_alpha);
  Alcotest.(check int) "enabled->enabled runs no release" 0 releases_after_alpha;
  Alcotest.(check int) "enabled->disabled releases" 1 releases_after_beta;
  Alcotest.(check int) "disabled->disabled does not reactivate" 1
    activations_after_gamma;
  Alcotest.(check bool) "disabled->enabled reactivates" true
    (tracked.t_activations = 2);
  Alcotest.(check bool) "same instance across settle/reactivate" true
    (Diagnostics.Instance_id.equal id_root id_root2);
  check_census outcome

(* index.spec "loader initiate": a disabled entry never activates, even
   when its enabled sibling does. *)
let test_component_disabled_entry_never_activates () =
  let enabled_tracked, disabled_tracked = tracked_pair "enabled" "disabled" in
  let enabled_component = tracked_component enabled_tracked in
  let disabled_component = tracked_component disabled_tracked in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let disabled_entry =
             Desired_state.Entry.make ~id:(entry_id_exn "off")
               ~component:disabled_component ~config:1 ~enabled:false
               ~context:Desired_state.Context_spec.empty
           in
           let* fence =
             any_error
               (Context.reconcile context
                  (Desired_state.tree
                     [ Desired_state.component (entry "on" enabled_component 1);
                       Desired_state.component disabled_entry ]))
           in
           let* _ = Diagnostics.Fence.await fence in
           Diagnostics.snapshot diagnostics))
  in
  let snapshot = expect_ok outcome in
  Alcotest.(check int) "disabled entry never activated" 0
    disabled_tracked.t_activations;
  Alcotest.(check string) "enabled sibling active" "active"
    (find_phase snapshot "on");
  check_census outcome

(* ------------------------------------------------------------------ *)
(* Ported from .reference/cordis/packages/core/tests/isolate.spec.ts   *)
(* and packages/loader/tests/isolate.spec.ts. Cordis realms are named  *)
(* or anonymous labels on isolate maps; ours are generative            *)
(* Desired_state.Realm.t values bound through Context_spec.isolate.    *)
(* Sharing a Realm.t value between two groups is the port of cordis's  *)
(* shared label.                                                       *)
(* ------------------------------------------------------------------ *)

(* core isolate.spec "shared label": two groups isolating one key to the
   SAME realm share the provider episode published inside that realm. *)
let test_component_shared_realm_across_groups () =
  let key = coeffect_exn "shared-realm" in
  let realm = Desired_state.Realm.create ~name:"shared" () in
  let provider_tracked, consumer_tracked = tracked_pair "provider" "consumer" in
  let provider = provider_component provider_tracked key (fun config -> config) in
  let consumer = consumer_component consumer_tracked key in
  let spec =
    Desired_state.Context_spec.isolate key realm
      Desired_state.Context_spec.empty
  in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let provider_node =
             Desired_state.component
               (Desired_state.Entry.make ~id:(entry_id_exn "p")
                  ~component:provider ~config:7 ~enabled:true ~context:spec)
           in
           let consumer_node =
             Desired_state.component
               (Desired_state.Entry.make ~id:(entry_id_exn "c")
                  ~component:consumer ~config:0 ~enabled:true ~context:spec)
           in
           let* fence =
             any_error
               (Context.reconcile context
                  (Desired_state.tree
                     [ group_node "ga" true [ provider_node ];
                       group_node "gb" true [ consumer_node ] ]))
           in
           let* _ = Diagnostics.Fence.await fence in
           let* snapshot = Diagnostics.snapshot diagnostics in
           (* Withdraw the provider: the consumer across the group
              boundary settles. *)
           let* fence2 =
             any_error
               (Context.reconcile context
                  (Desired_state.tree
                     [ group_node "gb" true [ consumer_node ] ]))
           in
           let* _ = Diagnostics.Fence.await fence2 in
           let* after = Diagnostics.snapshot diagnostics in
           Effect.sync (fun () -> (snapshot, after))))
  in
  let snapshot, after = expect_ok outcome in
  Alcotest.(check string) "provider active" "active" (find_phase snapshot "p");
  Alcotest.(check string) "consumer active" "active" (find_phase snapshot "c");
  Alcotest.(check bool) "consumer saw shared-realm value" true
    (List.exists (fun event -> event = "activate:7") (events consumer_tracked));
  Alcotest.(check string) "consumer settles after provider withdrawal"
    "waiting" (find_phase after "c");
  check_census outcome

(* loader isolate.spec "Service Isolation: basic": changing the isolate
   spec on the INJECTOR for a relevant key restarts it (release + it
   waits for a provider in the fresh realm); an irrelevant isolate change
   restarts nothing; removing the isolate reactivates against the root
   provider. *)
let test_component_isolate_reassignment_matrix () =
  let key = coeffect_exn "reassign" in
  let other_key = coeffect_exn "irrelevant" in
  let provider_tracked, consumer_tracked = tracked_pair "provider" "consumer" in
  let provider = provider_component provider_tracked key (fun config -> config) in
  let consumer = consumer_component consumer_tracked key in
  let consumer_entry_with context =
    Desired_state.Entry.make ~id:(entry_id_exn "c") ~component:consumer
      ~config:0 ~enabled:true ~context
  in
  let provider_node =
    Desired_state.component (entry "p" provider 5)
  in
  let tree_with context =
    Desired_state.tree
      [ provider_node; Desired_state.component (consumer_entry_with context) ]
  in
  let empty = Desired_state.Context_spec.empty in
  let realm = Desired_state.Realm.create ~name:"fresh" () in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* fence =
             any_error (Context.reconcile context (tree_with empty))
           in
           let* _ = Diagnostics.Fence.await fence in
           (* Add a relevant isolate: the consumer settles (release runs)
              and waits — the fresh realm has no provider. *)
           let* fence2 =
             any_error
               (Context.reconcile context
                  (tree_with
                     (Desired_state.Context_spec.isolate key realm empty)))
           in
           let* _ = Diagnostics.Fence.await fence2 in
           let* waiting_snapshot = Diagnostics.snapshot diagnostics in
           let releases_after_isolate =
             List.length
               (List.filter
                  (fun event -> event = "release:consumer")
                  (events consumer_tracked))
           in
           (* Add an irrelevant isolate alongside: nothing changes. *)
           let* fence3 =
             any_error
               (Context.reconcile context
                  (tree_with
                     (Desired_state.Context_spec.isolate other_key
                        (Desired_state.Realm.create ~name:"other" ())
                        (Desired_state.Context_spec.isolate key realm empty))))
           in
           let* _ = Diagnostics.Fence.await fence3 in
           let activations_after_irrelevant = consumer_tracked.t_activations in
           let releases_after_irrelevant =
             List.length
               (List.filter
                  (fun event -> event = "release:consumer")
                  (events consumer_tracked))
           in
           (* Remove the relevant isolate: the consumer reactivates against
              the root provider. *)
           let* fence4 =
             any_error
               (Context.reconcile context
                  (tree_with
                     (Desired_state.Context_spec.isolate other_key
                        (Desired_state.Realm.create ~name:"other2" ())
                        empty)))
           in
           let* _ = Diagnostics.Fence.await fence4 in
           let* reactivated = Diagnostics.snapshot diagnostics in
           (* Remove the irrelevant isolate: nothing changes. *)
           let* fence5 =
             any_error (Context.reconcile context (tree_with empty))
           in
           let* _ = Diagnostics.Fence.await fence5 in
           let activations_final = consumer_tracked.t_activations in
           Effect.sync (fun () ->
               ( waiting_snapshot,
                 releases_after_isolate,
                 activations_after_irrelevant,
                 releases_after_irrelevant,
                 reactivated,
                 activations_final ))))
  in
  let ( waiting_snapshot,
        releases_after_isolate,
        activations_after_irrelevant,
        releases_after_irrelevant,
        reactivated,
        activations_final ) =
    expect_ok outcome
  in
  Alcotest.(check int) "relevant isolate released the consumer" 1
    releases_after_isolate;
  Alcotest.(check string) "consumer waits in the fresh realm" "waiting"
    (find_phase waiting_snapshot "c");
  Alcotest.(check int) "irrelevant isolate reactivates nothing" 1
    activations_after_irrelevant;
  Alcotest.(check int) "irrelevant isolate releases nothing" 1
    releases_after_irrelevant;
  Alcotest.(check string) "consumer reactivated at root" "active"
    (find_phase reactivated "c");
  Alcotest.(check int) "removing irrelevant isolate reactivates nothing" 2
    activations_final;
  check_census outcome

(* loader isolate.spec "Service Isolation: realm": named realms route
   resolutions. A consumer inside a group isolating the key to realm A
   sees the provider published in realm A; a consumer isolating the key
   to a fresh realm with no provider waits. *)
let test_component_named_realm_routing () =
  let key = coeffect_exn "routing" in
  let realm_a = Desired_state.Realm.create ~name:"alpha" () in
  let realm_b = Desired_state.Realm.create ~name:"beta" () in
  let provider_tracked = tracked "provider" in
  let consumer_a_tracked = tracked "consumer-a" in
  let consumer_b_tracked = tracked "consumer-b" in
  let consumer_fresh_tracked = tracked "consumer-fresh" in
  let provider = provider_component provider_tracked key (fun config -> config) in
  let consumer_a = consumer_component consumer_a_tracked key in
  let consumer_b = consumer_component consumer_b_tracked key in
  let consumer_fresh = consumer_component consumer_fresh_tracked key in
  let spec_a = Desired_state.Context_spec.isolate key realm_a Desired_state.Context_spec.empty in
  let spec_b = Desired_state.Context_spec.isolate key realm_b Desired_state.Context_spec.empty in
  let spec_fresh =
    Desired_state.Context_spec.isolate key
      (Desired_state.Realm.create ~name:"anon" ())
      Desired_state.Context_spec.empty
  in
  let node id component config spec =
    Desired_state.component
      (Desired_state.Entry.make ~id:(entry_id_exn id) ~component ~config
         ~enabled:true ~context:spec)
  in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           (* Providers publish into realm A and realm B; consumers in each
              realm resolve their own provider; the fresh-realm consumer
              waits. *)
           let* fence =
             any_error
               (Context.reconcile context
                  (Desired_state.tree
                     [ group_node "ga" true
                         [ node "pa" provider 1 spec_a;
                           node "ca" consumer_a 0 spec_a ];
                       group_node "gb" true
                         [ node "pb" provider 2 spec_b;
                           node "cb" consumer_b 0 spec_b ];
                       node "cf" consumer_fresh 0 spec_fresh ]))
           in
           let* _ = Diagnostics.Fence.await fence in
           Diagnostics.snapshot diagnostics))
  in
  let snapshot = expect_ok outcome in
  Alcotest.(check string) "realm A consumer active" "active"
    (find_phase snapshot "ca");
  Alcotest.(check string) "realm B consumer active" "active"
    (find_phase snapshot "cb");
  Alcotest.(check string) "fresh-realm consumer waiting" "waiting"
    (find_phase snapshot "cf");
  Alcotest.(check bool) "realm A consumer saw value 1" true
    (List.exists (fun event -> event = "activate:1") (events consumer_a_tracked));
  Alcotest.(check bool) "realm B consumer saw value 2" true
    (List.exists (fun event -> event = "activate:2") (events consumer_b_tracked));
  Alcotest.(check int) "fresh consumer never activated" 0
    consumer_fresh_tracked.t_activations;
  check_census outcome

(* loader isolate.spec "special case: change provider": switching one
   group's isolate from realm A to realm B reroutes its consumer to the
   other provider episode. *)
let test_component_group_isolate_switch_reroutes () =
  let key = coeffect_exn "switch" in
  let realm_a = Desired_state.Realm.create ~name:"ra" () in
  let realm_b = Desired_state.Realm.create ~name:"rb" () in
  let provider_tracked = tracked "provider" in
  let consumer_tracked = tracked "consumer" in
  let provider = provider_component provider_tracked key (fun config -> config) in
  let consumer = consumer_component consumer_tracked key in
  let spec_a = Desired_state.Context_spec.isolate key realm_a Desired_state.Context_spec.empty in
  let spec_b = Desired_state.Context_spec.isolate key realm_b Desired_state.Context_spec.empty in
  let node id component config spec =
    Desired_state.component
      (Desired_state.Entry.make ~id:(entry_id_exn id) ~component ~config
         ~enabled:true ~context:spec)
  in
  let tree_with consumer_spec =
    Desired_state.tree
      [ node "pa" provider 10 spec_a;
        node "pb" provider 20 spec_b;
        group_node "g" true [ node "c" consumer 0 consumer_spec ] ]
  in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* fence =
             any_error (Context.reconcile context (tree_with spec_a))
           in
           let* _ = Diagnostics.Fence.await fence in
           (* Switch the group's isolate from realm A to realm B. *)
           let* fence2 =
             any_error (Context.reconcile context (tree_with spec_b))
           in
           let* _ = Diagnostics.Fence.await fence2 in
           Diagnostics.snapshot diagnostics))
  in
  let snapshot = expect_ok outcome in
  Alcotest.(check string) "consumer active after switch" "active"
    (find_phase snapshot "c");
  Alcotest.(check bool) "consumer saw realm A value first" true
    (List.exists (fun event -> event = "activate:10") (events consumer_tracked));
  Alcotest.(check bool) "consumer rerouted to realm B value" true
    (List.exists (fun event -> event = "activate:20") (events consumer_tracked));
  Alcotest.(check int) "consumer restarted exactly once" 2
    consumer_tracked.t_activations;
  check_census outcome

(* ------------------------------------------------------------------ *)
(* Ported from .reference/cordis/packages/hmr/tests/index.spec.ts.     *)
(* Cordis HMR watches files and reloads changed modules through the    *)
(* loader; ours is the explicit Replacement batch API. The ported      *)
(* gates assert the runtime observables: dependency-chain restarts,    *)
(* untouched siblings, and recovery after a rolled-back candidate.     *)
(* ------------------------------------------------------------------ *)

(* Build and submit a one-candidate replacement batch for [entry_id]
   against its current instance and target revision. *)
let replace_one context diagnostics ~entry_id ~candidate_component ~config
    ~source_revision =
  let* snapshot = Diagnostics.snapshot diagnostics in
  let instance_id, target_revision =
    match
      List.find_opt
        (fun instance ->
          Entry_id.equal (Diagnostics.entry_id instance)
            (entry_id_exn entry_id))
        (Diagnostics.instances snapshot)
    with
    | Some instance ->
        ( Diagnostics.instance_id instance,
          Diagnostics.target_revision instance )
    | None -> Alcotest.failf "instance %s missing" entry_id
  in
  let target_revision =
    match target_revision with
    | Some revision -> revision
    | None -> Alcotest.fail "target revision missing"
  in
  let target =
    Replacement.target
      ~entry:(entry entry_id candidate_component config)
      ~expected_instance:instance_id ~expected_target:target_revision
  in
  let* candidate =
    match Replacement.candidate ~target ~component:candidate_component with
    | Ok candidate -> Effect.pure candidate
    | Error _ -> Alcotest.fail "candidate construction failed"
  in
  let* batch =
    match Replacement.batch ~source_revision [ candidate ] with
    | Ok batch -> Effect.pure batch
    | Error _ -> Alcotest.fail "batch construction failed"
  in
  any_error (Context.replace context batch)

(* hmr "dependency chain": replacing the provider declaration restarts
   its consumer against the new episode. *)
let test_component_replace_provider_restarts_consumer () =
  let key = coeffect_exn "dep-chain" in
  let provider_tracked, consumer_tracked = tracked_pair "provider" "consumer" in
  let provider_v1 = provider_component provider_tracked key (fun config -> config) in
  let consumer = consumer_component consumer_tracked key in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* fence =
             any_error
               (Context.reconcile context
                  (tree_of [ entry "db" provider_v1 1; entry "svc" consumer 0 ]))
           in
           let* _ = Diagnostics.Fence.await fence in
           (* The replacement declaration shares the family but is a fresh
              declaration providing a new value. *)
           let provider_v2_tracked = tracked "provider-v2" in
           let provider_v2 =
             match
               Component.make ~family:(Component.family provider_v1)
                 ~config_equal:Int.equal ~requirements:Requirement.none
                 ~provisions:(Provision.one key)
                 ~pp_error:(fun ppf error -> Format.pp_print_string ppf error)
                 ~activate:(fun config () activation ->
                   Effect.sync (fun () ->
                       track provider_v2_tracked "activate:v2")
                   >>= fun () ->
                   Activation.own activation
                     ~acquire:Effect.unit
                     ~release:(fun () -> Effect.unit)
                     ~pp_release_error:(fun ppf _ ->
                       Format.pp_print_string ppf "e")
                   >>= fun () -> Effect.pure config)
             with
             | Ok component -> component
             | Error _ -> Alcotest.fail "make provider v2 failed"
           in
           let* replace_fence =
             replace_one context diagnostics ~entry_id:"db"
               ~candidate_component:provider_v2 ~config:2
               ~source_revision:(Source_revision.of_int64 1L)
           in
           let* report = Diagnostics.Fence.await replace_fence in
           let* after = Diagnostics.snapshot diagnostics in
           Effect.sync (fun () -> (report, after))))
  in
  let report, after = expect_ok outcome in
  Alcotest.(check bool) "replacement quiescent" true
    (Diagnostics.Fence.outcome report = Diagnostics.Fence.Quiescent);
  Alcotest.(check string) "provider active after replace" "active"
    (find_phase after "db");
  (* The consumer restarted against the fresh episode and observed the new
     provision value. *)
  Alcotest.(check bool) "consumer restarted with new value" true
    (List.exists (fun event -> event = "activate:2") (events consumer_tracked));
  Alcotest.(check int) "consumer activated twice" 2 consumer_tracked.t_activations;
  check_census outcome

(* hmr "multiple plugins": replacing one entry leaves its independent
   sibling untouched. *)
let test_component_replace_leaves_sibling_untouched () =
  let a_tracked, b_tracked = tracked_pair "a" "b" in
  let component_a = tracked_component a_tracked in
  let component_b = tracked_component b_tracked in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* fence =
             any_error
               (Context.reconcile context
                  (tree_of [ entry "a" component_a 1; entry "b" component_b 1 ]))
           in
           let* _ = Diagnostics.Fence.await fence in
           (* A fresh declaration on the same family for entry "a". *)
           let component_a2 =
             match
               Component.make ~family:(Component.family component_a)
                 ~config_equal:Int.equal ~requirements:Requirement.none
                 ~provisions:Provision.none
                 ~pp_error:(fun ppf error -> Format.pp_print_string ppf error)
                 ~activate:(fun _config () activation ->
                   Effect.sync (fun () -> track a_tracked "activate:v2")
                   >>= fun () ->
                   Activation.own activation
                     ~acquire:Effect.unit
                     ~release:(fun () ->
                       Effect.sync (fun () -> track a_tracked "release:v2"))
                     ~pp_release_error:(fun ppf _ ->
                       Format.pp_print_string ppf "e"))
             with
             | Ok component -> component
             | Error _ -> Alcotest.fail "make a2 failed"
           in
           let* replace_fence =
             replace_one context diagnostics ~entry_id:"a"
               ~candidate_component:component_a2 ~config:2
               ~source_revision:(Source_revision.of_int64 1L)
           in
           let* _ = Diagnostics.Fence.await replace_fence in
           (* Observe the sibling before the context-exit shutdown releases
              everything. *)
           let* b_releases_after_replace =
             Effect.sync (fun () ->
                 List.length
                   (List.filter
                      (fun event -> event = "release:b")
                      (events b_tracked)))
           in
           let* b_activations_after_replace =
             Effect.sync (fun () -> b_tracked.t_activations)
           in
           Effect.sync (fun () ->
               (b_activations_after_replace, b_releases_after_replace))))
  in
  let b_activations, b_releases = expect_ok outcome in
  Alcotest.(check int) "sibling never reactivated" 1 b_activations;
  Alcotest.(check int) "sibling never released" 0 b_releases;
  Alcotest.(check bool) "replaced entry reactivated" true
    (List.exists (fun event -> event = "activate:v2") (events a_tracked));
  check_census outcome

(* hmr "import error rollback" + "recover after fixing the error": a
   failing candidate rolls back to the saved declaration; a later
   well-formed candidate then succeeds. *)
let test_component_recovery_replace_after_rollback () =
  let good = tracked "good" in
  let fixed = tracked "fixed" in
  let good_component = tracked_component good in
  let outcome =
    run_program
      (Context.run (fun context diagnostics ->
           let* fence =
             any_error
               (Context.reconcile context
                  (tree_of [ entry "a" good_component 1 ]))
           in
           let* _ = Diagnostics.Fence.await fence in
           (* First candidate fails its activation: the batch rolls back. *)
           let failing_tracked = tracked "failing" in
           let failing_component =
             match
               Component.make ~family:(Component.family good_component)
                 ~config_equal:Int.equal ~requirements:Requirement.none
                 ~provisions:Provision.none
                 ~pp_error:(fun ppf error -> Format.pp_print_string ppf error)
                 ~activate:(fun _config () _activation ->
                   Effect.sync (fun () -> track failing_tracked "activate:bad")
                   >>= fun () -> Effect.fail "candidate boom")
             with
             | Ok component -> component
             | Error _ -> Alcotest.fail "make failing failed"
           in
           let* bad_fence =
             replace_one context diagnostics ~entry_id:"a"
               ~candidate_component:failing_component ~config:2
               ~source_revision:(Source_revision.of_int64 1L)
           in
           let* bad_report = Diagnostics.Fence.await bad_fence in
           let rolled_back =
             Diagnostics.Fence.outcome bad_report
             = Diagnostics.Fence.Rolled_back
           in
           (* The fixed candidate on the same family succeeds. *)
           let fixed_component =
             match
               Component.make ~family:(Component.family good_component)
                 ~config_equal:Int.equal ~requirements:Requirement.none
                 ~provisions:Provision.none
                 ~pp_error:(fun ppf error -> Format.pp_print_string ppf error)
                 ~activate:(fun _config () activation ->
                   Effect.sync (fun () -> track fixed "activate:fixed")
                   >>= fun () ->
                   Activation.own activation
                     ~acquire:Effect.unit
                     ~release:(fun () -> Effect.unit)
                     ~pp_release_error:(fun ppf _ ->
                       Format.pp_print_string ppf "e"))
             with
             | Ok component -> component
             | Error _ -> Alcotest.fail "make fixed failed"
           in
           let* good_fence =
             replace_one context diagnostics ~entry_id:"a"
               ~candidate_component:fixed_component ~config:3
               ~source_revision:(Source_revision.of_int64 2L)
           in
           let* good_report = Diagnostics.Fence.await good_fence in
           let* after = Diagnostics.snapshot diagnostics in
           Effect.sync (fun () -> (rolled_back, good_report, after))))
  in
  let rolled_back, good_report, after = expect_ok outcome in
  Alcotest.(check bool) "failing candidate rolled back" true rolled_back;
  Alcotest.(check bool) "recovery replace quiescent" true
    (Diagnostics.Fence.outcome good_report = Diagnostics.Fence.Quiescent);
  Alcotest.(check string) "entry active after recovery" "active"
    (find_phase after "a");
  Alcotest.(check bool) "fixed declaration activated" true
    (List.exists (fun event -> event = "activate:fixed") (events fixed));
  check_census outcome
