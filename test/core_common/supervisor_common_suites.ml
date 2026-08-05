module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  open Eta

  module E = Effect

  let pp_hidden ppf _ = Format.pp_print_string ppf "<supervisor>"

  let run_ok rt eff =
    match B.run rt eff with
    | Exit.Ok value -> value
    | Exit.Error cause ->
        Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause

  let rec wait_until_effect ?(attempts = 200) pred =
    if pred () then E.unit
    else if attempts = 0 then
      E.sync (fun () -> Alcotest.fail "condition did not become true")
    else
      B.yield_effect ()
      |> E.bind (fun () -> wait_until_effect ~attempts:(attempts - 1) pred)

  let wait_for_sleepers_effect clock expected =
    wait_until_effect (fun () -> B.sleeper_count clock >= expected)

  let rec finalizer_contains expected = function
    | Cause.Finalizer.Fail { error = _; rendered } -> String.equal expected rendered
    | Cause.Finalizer.Die _ | Cause.Finalizer.Interrupt _ -> false
    | Cause.Finalizer.Sequential causes | Cause.Finalizer.Concurrent causes ->
        List.exists (finalizer_contains expected) causes
    | Cause.Finalizer.Finalizer cause -> finalizer_contains expected cause
    | Cause.Finalizer.Suppressed { primary; finalizer } ->
        finalizer_contains expected primary || finalizer_contains expected finalizer

  let test_supervisor_observes_child_failure () =
    B.with_runtime @@ fun _ctx rt ->
    let program =
      Supervisor.scoped {
        run =
          fun (type s) sup ->
            let open Supervisor.Scope in
            let* (_child : (s, [> `Boom ], int) Supervisor.child) =
              start sup (fail `Boom)
            in
            let* () = yield in
            failures sup;
      }
    in
    match B.run rt program with
    | Exit.Ok [ Cause.Fail `Boom ] -> ()
    | _ -> Alcotest.fail "expected observed child failure"

  let test_supervisor_child_finalizer_uses_parent_error_renderer () =
    B.with_runtime @@ fun _ctx rt ->
    let render fmt = function
      | `Cleanup_failed -> Format.pp_print_string fmt "rendered cleanup"
    in
    let child =
      E.acquire_release ~acquire:E.unit
        ~release:(fun () -> E.fail `Cleanup_failed)
    in
    let program =
      Supervisor.scoped {
        run =
          fun (type s) sup ->
            let open Supervisor.Scope in
            let* (_child : (s, [> `Cleanup_failed ], unit) Supervisor.child) =
              start sup (lift child)
            in
            let* () = yield in
            failures sup;
      }
      |> Eta_observability.with_error_pp render
    in
    match B.run rt program with
    | Exit.Ok [ Cause.Finalizer finalizer ] ->
        Alcotest.(check bool)
          "custom renderer" true
          (finalizer_contains "rendered cleanup" finalizer)
    | Exit.Ok failures ->
        Alcotest.failf "expected one child finalizer failure, got %d"
          (List.length failures)
    | Exit.Error cause ->
        Alcotest.failf "unexpected supervisor failure: %a"
          (Cause.pp pp_hidden) cause

  let test_supervisor_await_rethrows_child_failure () =
    B.with_runtime @@ fun _ctx rt ->
    let program =
      Supervisor.scoped {
        run =
          fun (type s) sup ->
            let open Supervisor.Scope in
            let* (child : (s, [> `Boom ], int) Supervisor.child) =
              start sup (fail `Boom)
            in
            await child;
      }
    in
    match B.run rt program with
    | Exit.Error (Cause.Fail `Boom) -> ()
    | _ -> Alcotest.fail "expected await to rethrow child failure"

  let test_supervisor_cancel_before_await_does_not_deadlock () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let child = E.delay (Duration.ms 1_000) E.unit in
    let program =
      Supervisor.scoped {
        run =
          fun (type s) sup ->
            let open Supervisor.Scope in
            let* (child : (s, [> `Boom ], unit) Supervisor.child) =
              start sup (lift child)
            in
            let* () = cancel child in
            await child;
      }
    in
    match B.run rt program with
    | Exit.Error (Cause.Interrupt None) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected Interrupt, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok () -> Alcotest.fail "expected Interrupt, got Ok"

  let test_supervisor_cancel_runs_finalizer () =
    B.with_test_clock @@ fun _ctx clock rt ->
    let finalizer_ran = ref false in
    let child =
      E.acquire_release
        ~acquire:(Eta_observability.named "supervisor.acquire" (E.sync (fun () -> ())))
        ~release:(fun () ->
          Eta_observability.named "supervisor.release"
            (E.sync (fun () -> finalizer_ran := true)))
      |> E.bind (fun () -> E.delay (Duration.ms 1_000) E.unit)
    in
    let program =
      Supervisor.scoped {
        run =
          fun (type s) sup ->
            let open Supervisor.Scope in
            let* (child : (s, [> `Boom ], unit) Supervisor.child) =
              start sup (lift child)
            in
            let* () = lift (wait_for_sleepers_effect clock 1) in
            let* () = cancel child in
            await child;
      }
    in
    match B.run rt program with
    | Exit.Error (Cause.Interrupt None) ->
        Alcotest.(check bool) "finalizer ran" true !finalizer_ran
    | Exit.Error cause ->
        Alcotest.failf "expected Interrupt, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok () -> Alcotest.fail "expected Interrupt, got Ok"

  let test_supervisor_cancel_waits_for_finalizer () =
    B.with_test_clock @@ fun _ctx clock rt ->
    let finalizer_ran = ref false in
    let child =
      E.acquire_release
        ~acquire:(Eta_observability.named "supervisor.acquire" (E.sync (fun () -> ())))
        ~release:(fun () ->
          Eta_observability.named "supervisor.release"
            (E.sync (fun () -> finalizer_ran := true)))
      |> E.bind (fun () -> E.delay (Duration.ms 1_000) E.unit)
    in
    let program =
      Supervisor.scoped {
        run =
          fun sup ->
            let open Supervisor.Scope in
            let* child = start sup (lift child) in
            let* () = lift (wait_for_sleepers_effect clock 1) in
            let* () = cancel child in
            lift (E.sync (fun () -> !finalizer_ran));
      }
    in
    match B.run rt program with
    | Exit.Ok true -> ()
    | Exit.Ok false -> Alcotest.fail "expected cancel to wait for finalizer"
    | Exit.Error cause ->
        Alcotest.failf "unexpected cancel failure: %a" (Cause.pp pp_hidden) cause

  let test_effect_with_supervised_background_cancels_child () =
    B.with_test_clock @@ fun _ctx clock rt ->
    let finalizer_ran = ref false in
    let child_started = ref false in
    let background =
      E.acquire_release
        ~acquire:
          (E.sync (fun () ->
               child_started := true;
               ()))
        ~release:(fun () -> E.sync (fun () -> finalizer_ran := true))
      |> E.bind (fun () -> E.delay (Duration.ms 1_000) E.unit)
    in
    let program =
      E.with_supervised_background background (fun () ->
          wait_for_sleepers_effect clock 1
          |> E.map (fun () -> !child_started))
    in
    match B.run rt program with
    | Exit.Ok true -> Alcotest.(check bool) "finalizer ran" true !finalizer_ran
    | Exit.Ok false -> Alcotest.fail "background did not start"
    | Exit.Error cause ->
        Alcotest.failf "unexpected with_supervised_background failure: %a"
          (Cause.pp pp_hidden) cause

  let test_effect_with_supervised_background_reports_child_cleanup_failure () =
    B.with_test_clock @@ fun _ctx clock rt ->
    let child_started = ref false in
    let background =
      E.acquire_release
        ~acquire:(E.sync (fun () -> child_started := true))
        ~release:(fun () -> E.fail `Cleanup_failed)
      |> E.bind (fun () -> E.delay (Duration.ms 1_000) E.unit)
    in
    let program =
      E.with_supervised_background background (fun () ->
          wait_for_sleepers_effect clock 1 |> E.map (fun () -> !child_started))
    in
    match B.run rt program with
    | Exit.Error (Cause.Finalizer finalizer) ->
        Alcotest.(check bool)
          "background cleanup failure surfaced" true
          (finalizer_contains "<typed failure>" finalizer)
    | Exit.Error cause ->
        Alcotest.failf "expected background cleanup finalizer failure, got %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok false -> Alcotest.fail "background did not start"
    | Exit.Ok true -> Alcotest.fail "background cleanup failure was hidden"

  let test_effect_with_supervised_background_cancels_after_use_failure () =
    B.with_test_clock @@ fun _ctx clock rt ->
    let finalizer_ran = ref false in
    let background =
      E.acquire_release ~acquire:E.unit
        ~release:(fun () -> E.sync (fun () -> finalizer_ran := true))
      |> E.bind (fun () -> E.delay (Duration.ms 1_000) E.unit)
    in
    let program =
      E.with_supervised_background background (fun () ->
          wait_for_sleepers_effect clock 1 |> E.bind (fun () -> E.fail `Use_failed))
    in
    (match B.run rt program with
    | Exit.Error (Cause.Fail `Use_failed) -> ()
    | Exit.Error cause ->
        Alcotest.failf "unexpected with_supervised_background failure: %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "failing use unexpectedly succeeded");
    Alcotest.(check bool) "background finalizer ran" true !finalizer_ran

  let test_effect_with_background_typed_failure_cancels_use () =
    B.with_runtime @@ fun ctx rt ->
    let go, release = B.create_promise () in
    let ready, mark_ready = B.create_promise () in
    let body_finalizers = ref 0 in
    let background =
      B.await_effect go |> E.bind (fun () -> E.fail `Background_failed)
    in
    let use =
      E.finally (E.sync (fun () -> incr body_finalizers))
        (E.sync (fun () -> B.resolve mark_ready ())
        |> E.bind (fun () -> E.never))
    in
    let promise =
      B.fork_run ctx rt (E.with_background background (fun () -> use))
    in
    B.await ready;
    B.resolve release ();
    (match B.await promise with
    | Exit.Error (Cause.Fail `Background_failed) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected background typed failure, got %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "background typed failure was hidden");
    Alcotest.(check int) "body finalizer count" 1 !body_finalizers

  let test_effect_with_background_defect_cancels_use () =
    B.with_runtime @@ fun ctx rt ->
    let go, release = B.create_promise () in
    let ready, mark_ready = B.create_promise () in
    let body_finalizers = ref 0 in
    let defect = Failure "background defect" in
    let background =
      B.await_effect go |> E.bind (fun () -> E.sync (fun () -> raise defect))
    in
    let use =
      E.finally (E.sync (fun () -> incr body_finalizers))
        (E.sync (fun () -> B.resolve mark_ready ())
        |> E.bind (fun () -> E.never))
    in
    let promise =
      B.fork_run ctx rt (E.with_background background (fun () -> use))
    in
    B.await ready;
    B.resolve release ();
    (match B.await promise with
    | Exit.Error (Cause.Die die) when die.exn == defect -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected background defect, got %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "background defect was hidden");
    Alcotest.(check int) "body finalizer count" 1 !body_finalizers

  let test_effect_with_background_body_exit_cancels_and_awaits () =
    let run_case body expected =
      B.with_test_clock @@ fun _ctx clock rt ->
      let background_finalizers = ref 0 in
      let background =
        E.finally (E.sync (fun () -> incr background_finalizers))
          (E.delay (Duration.ms 1_000) E.unit)
      in
      let program =
        E.with_background background (fun () ->
            wait_for_sleepers_effect clock 1 |> E.bind body)
      in
      (match (B.run rt program, expected) with
      | Exit.Ok "ok", `Success -> ()
      | Exit.Error (Cause.Fail `Use_failed), `Failure -> ()
      | Exit.Error cause, _ ->
          Alcotest.failf "unexpected body-first cause: %a" (Cause.pp pp_hidden)
            cause
      | Exit.Ok value, _ -> Alcotest.failf "unexpected body value: %s" value);
      Alcotest.(check int)
        "background finalizer count" 1 !background_finalizers
    in
    run_case (fun () -> E.pure "ok") `Success;
    run_case (fun () -> E.fail `Use_failed) `Failure

  let test_effect_with_background_body_interruption_matches_par () =
    B.with_runtime @@ fun _ctx rt ->
    let ready, mark_ready = B.create_promise () in
    let background_finalizers = ref 0 in
    let background =
      E.finally (E.sync (fun () -> incr background_finalizers))
        (E.sync (fun () -> B.resolve mark_ready ())
        |> E.bind (fun () -> E.never))
    in
    let scoped = E.with_background background (fun () -> E.never) in
    let controller = B.await_effect ready |> E.bind (fun () -> E.fail `Stop) in
    (match B.run rt (E.discard (E.par scoped controller)) with
    | Exit.Error (Cause.Fail `Stop) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected par interruption shape, got %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok () -> Alcotest.fail "interrupted background scope succeeded");
    Alcotest.(check int)
      "background finalizer count" 1 !background_finalizers

  let test_effect_with_supervised_background_failure_does_not_cancel_use () =
    B.with_runtime @@ fun ctx rt ->
    let go, release = B.create_promise () in
    let body_started, mark_started = B.create_promise () in
    let body_finished, finish_body = B.create_promise () in
    let body_completed = ref false in
    let background =
      B.await_effect go |> E.bind (fun () -> E.fail `Background_failed)
    in
    let use =
      E.sync (fun () -> B.resolve mark_started ())
      |> E.bind (fun () -> B.await_effect body_finished)
      |> E.map (fun () -> body_completed := true)
    in
    let promise =
      B.fork_run ctx rt
        (E.with_supervised_background background (fun () -> use))
    in
    B.await body_started;
    B.resolve release ();
    B.yield ();
    Alcotest.(check bool) "body still running" false !body_completed;
    B.resolve finish_body ();
    (match B.await promise with
    | Exit.Error (Cause.Finalizer _) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected supervised cleanup diagnostic, got %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok () -> Alcotest.fail "supervised child failure was hidden at cleanup");
    Alcotest.(check bool) "body completed" true !body_completed

  let test_effect_with_background_same_release_has_one_winner () =
    B.with_runtime @@ fun ctx rt ->
    let go, release = B.create_promise () in
    let ready = B.create_stream 2 in
    let published = B.create_stream 2 in
    let body_finalizers = ref 0 in
    let background_finalizers = ref 0 in
    let background =
      E.finally (E.sync (fun () -> incr background_finalizers))
        (E.sync (fun () -> B.stream_add ready `Background)
        |> E.bind (fun () -> B.await_effect go)
        |> E.bind (fun () ->
               E.sync (fun () -> B.stream_add published `Background))
        |> E.bind (fun () -> E.fail `Background_failed))
    in
    let use =
      E.finally (E.sync (fun () -> incr body_finalizers))
        (E.sync (fun () -> B.stream_add ready `Body)
        |> E.bind (fun () -> B.await_effect go)
        |> E.bind (fun () -> E.sync (fun () -> B.stream_add published `Body)))
    in
    let promise =
      B.fork_run ctx rt (E.with_background background (fun () -> use))
    in
    ignore (B.stream_take ready : [ `Background | `Body ]);
    ignore (B.stream_take ready : [ `Background | `Body ]);
    B.resolve release ();
    let first = B.stream_take published in
    (match (first, B.await promise) with
    | `Background, Exit.Error (Cause.Fail `Background_failed) -> ()
    | `Body, Exit.Ok () -> ()
    | `Body, Exit.Error (Cause.Finalizer finalizer)
      when finalizer_contains "<typed failure>" finalizer ->
        ()
    | first, Exit.Error cause ->
        Alcotest.failf "first=%s, unexpected same-release cause: %a"
          (match first with `Background -> "background" | `Body -> "body")
          (Cause.pp pp_hidden) cause
    | `Background, Exit.Ok () ->
        Alcotest.fail "published background failure lost to body success");
    Alcotest.(check int) "body finalized once" 1 !body_finalizers;
    Alcotest.(check int) "background finalized once" 1 !background_finalizers

  let rec finalizer_shape = function
    | Cause.Finalizer.Fail { error = _; rendered } -> Printf.sprintf "Fail(%s)" rendered
    | Cause.Finalizer.Die die ->
        Printf.sprintf "Die(%s)" (Printexc.to_string die.exn)
    | Cause.Finalizer.Interrupt _ -> "Interrupt"
    | Cause.Finalizer.Sequential causes ->
        Printf.sprintf "Sequential[%s]"
          (String.concat ";" (List.map finalizer_shape causes))
    | Cause.Finalizer.Concurrent causes ->
        Printf.sprintf "Concurrent[%s]"
          (String.concat ";" (List.map finalizer_shape causes))
    | Cause.Finalizer.Finalizer cause ->
        Printf.sprintf "Finalizer(%s)" (finalizer_shape cause)
    | Cause.Finalizer.Suppressed { primary; finalizer } ->
        Printf.sprintf "Suppressed(%s,%s)" (finalizer_shape primary)
          (finalizer_shape finalizer)

  let rec cause_shape render = function
    | Cause.Fail err -> Printf.sprintf "Fail(%s)" (render err)
    | Cause.Die die -> Printf.sprintf "Die(%s)" (Printexc.to_string die.exn)
    | Cause.Interrupt _ -> "Interrupt"
    | Cause.Sequential causes ->
        Printf.sprintf "Sequential[%s]"
          (String.concat ";" (List.map (cause_shape render) causes))
    | Cause.Concurrent causes ->
        Printf.sprintf "Concurrent[%s]"
          (String.concat ";" (List.map (cause_shape render) causes))
    | Cause.Finalizer cause ->
        Printf.sprintf "Finalizer(%s)" (finalizer_shape cause)
    | Cause.Suppressed { primary; finalizer } ->
        Printf.sprintf "Suppressed(%s,%s)" (cause_shape render primary)
          (finalizer_shape finalizer)

  let background_error_name = function
    | `Background_failed -> "Background_failed"
    | `Body_failed -> "Body_failed"
    | `Cleanup_failed -> "Cleanup_failed"

  let pp_background_error ppf err =
    Format.pp_print_string ppf (background_error_name err)

  let exit_shape = function
    | Exit.Ok _ -> "Ok"
    | Exit.Error cause -> cause_shape background_error_name cause

  let run_cleanup_parity_case make body =
    B.with_test_clock @@ fun _ctx clock rt ->
    let background =
      E.acquire_release ~acquire:E.unit
        ~release:(fun () -> E.fail `Cleanup_failed)
      |> E.bind (fun () -> E.delay (Duration.ms 1_000) E.unit)
    in
    let program =
      make background (fun () -> wait_for_sleepers_effect clock 1 |> E.bind body)
      |> Eta_observability.with_error_pp pp_background_error
    in
    B.run rt program

  let check_cleanup_parity expected body =
    let old_shape =
      run_cleanup_parity_case E.with_supervised_background body |> exit_shape
    in
    let new_shape =
      run_cleanup_parity_case E.with_background body |> exit_shape
    in
    Alcotest.(check string) "old exact tree" expected old_shape;
    Alcotest.(check string) "new exact tree" expected new_shape;
    Alcotest.(check string) "old/new structural parity" old_shape new_shape

  let test_background_cleanup_after_body_success_matches_old_shape () =
    check_cleanup_parity
      "Finalizer(Suppressed(Interrupt,Fail(Cleanup_failed)))"
      (fun () -> E.unit)

  let test_background_cleanup_after_body_failure_matches_old_shape () =
    check_cleanup_parity
      "Suppressed(Fail(Body_failed),Suppressed(Interrupt,Fail(Cleanup_failed)))"
      (fun () -> E.fail `Body_failed)

  let test_background_cleanup_after_body_defect_matches_old_shape () =
    let defect = Failure "body defect" in
    let body () = E.sync (fun () -> raise defect) in
    check_cleanup_parity
      "Suppressed(Die(Failure(\"body defect\")),Suppressed(Interrupt,Fail(Cleanup_failed)))"
      body

  let test_background_loser_publishes_after_cancellation_before_assembly () =
    B.with_runtime @@ fun ctx rt ->
    let body_ready, mark_body_ready = B.create_promise () in
    let finalizer_started, mark_finalizer_started = B.create_promise () in
    let release_finalizer, release = B.create_promise () in
    let finalizer_finished = ref false in
    let background =
      B.await_effect body_ready
      |> E.bind (fun () -> E.fail `Background_failed)
    in
    let use =
      E.finally
        (E.sync (fun () -> B.resolve mark_finalizer_started ())
        |> E.bind (fun () -> B.await_effect release_finalizer)
        |> E.map (fun () -> finalizer_finished := true))
        (E.sync (fun () -> B.resolve mark_body_ready ())
        |> E.bind (fun () -> E.never))
    in
    let result =
      B.fork_run ctx rt (E.with_background background (fun () -> use))
    in
    B.await finalizer_started;
    Alcotest.(check bool) "arbiter still waiting" false (B.is_resolved result);
    B.resolve release ();
    (match B.await result with
    | Exit.Error (Cause.Fail `Background_failed) -> ()
    | Exit.Error cause ->
        Alcotest.failf "unexpected post-cancel publication cause: %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "background failure was lost");
    Alcotest.(check bool) "loser finalizer finished" true !finalizer_finished

  let test_background_winner_preserves_body_cleanup_failure () =
    B.with_runtime @@ fun _ctx rt ->
    let body_ready, mark_body_ready = B.create_promise () in
    let cleanup_count = ref 0 in
    let background =
      B.await_effect body_ready
      |> E.bind (fun () -> E.fail `Background_failed)
    in
    let use =
      E.acquire_release ~acquire:E.unit
        ~release:(fun () ->
          E.sync (fun () -> incr cleanup_count)
          |> E.bind (fun () -> E.fail `Cleanup_failed))
      |> E.bind (fun () ->
             E.sync (fun () -> B.resolve mark_body_ready ())
             |> E.bind (fun () -> E.never))
    in
    let exit =
      E.with_background background (fun () -> use)
      |> Eta_observability.with_error_pp pp_background_error |> B.run rt
    in
    Alcotest.(check string)
      "background primary with complete body cleanup cause"
      "Suppressed(Fail(Background_failed),Suppressed(Interrupt,Fail(Cleanup_failed)))"
      (exit_shape exit);
    Alcotest.(check int) "body cleanup exactly once" 1 !cleanup_count

  let test_supervisor_threshold_failure () =
    B.with_runtime @@ fun _ctx rt ->
    let program =
      Supervisor.scoped ~max_failures:1 {
        run =
          fun (type s) sup ->
            let open Supervisor.Scope in
            let* (_child :
                    (s, [> `Boom | `Supervisor_failed of int ], int)
                    Supervisor.child) =
              start sup (fail `Boom)
            in
            let* () = yield in
            check sup;
      }
    in
    match B.run rt program with
    | Exit.Error (Cause.Fail (`Supervisor_failed 1)) -> ()
    | _ -> Alcotest.fail "expected supervisor threshold failure"

  let test_supervisor_records_multiple_failures () =
    B.with_runtime @@ fun _ctx rt ->
    let program =
      Supervisor.scoped {
        run =
          fun (type s) sup ->
            let open Supervisor.Scope in
            let* (_left : (s, [> `Left | `Right ], unit) Supervisor.child) =
              start sup (fail `Left)
            in
            let* (_right : (s, [> `Left | `Right ], unit) Supervisor.child) =
              start sup (fail `Right)
            in
            let* () = yield in
            failures sup;
      }
    in
    match B.run rt program with
    | Exit.Ok failures ->
        let rendered =
          failures
          |> List.map (function
               | Cause.Fail `Left -> "left"
               | Cause.Fail `Right -> "right"
               | _ -> "other")
          |> List.sort String.compare
        in
        Alcotest.(check (list string)) "failures" [ "left"; "right" ] rendered
    | Exit.Error _ -> Alcotest.fail "expected supervisor failures snapshot"

  let test_supervisor_nested_scopes_compose () =
    B.with_runtime @@ fun _ctx rt ->
    let inner =
      Supervisor.scoped {
        run =
          fun (type s) sup ->
            let open Supervisor.Scope in
            let* (_child : (s, [> `Inner ], unit) Supervisor.child) =
              start sup (fail `Inner)
            in
            let* () = yield in
            failures sup;
      }
    in
    let outer =
      Supervisor.scoped {
        run =
          fun (_ : (_, _) Supervisor.t) ->
            let open Supervisor.Scope in
            let* inner_failures = lift inner in
            pure (List.length inner_failures);
      }
    in
    Alcotest.(check int) "inner failure observed" 1 (run_ok rt outer)

  let tests =
    [
      ( "Supervisor",
        [
          Alcotest.test_case "observes child failure" `Quick
            test_supervisor_observes_child_failure;
          Alcotest.test_case "child finalizer uses parent renderer" `Quick
            test_supervisor_child_finalizer_uses_parent_error_renderer;
          Alcotest.test_case "await rethrows child failure" `Quick
            test_supervisor_await_rethrows_child_failure;
          Alcotest.test_case "cancel before await does not deadlock" `Quick
            test_supervisor_cancel_before_await_does_not_deadlock;
          Alcotest.test_case "cancel runs finalizer" `Quick
            test_supervisor_cancel_runs_finalizer;
          Alcotest.test_case "cancel waits for finalizer" `Quick
            test_supervisor_cancel_waits_for_finalizer;
          Alcotest.test_case "with_supervised_background cancels child" `Quick
            test_effect_with_supervised_background_cancels_child;
          Alcotest.test_case
            "with_supervised_background reports cleanup failure" `Quick
            test_effect_with_supervised_background_reports_child_cleanup_failure;
          Alcotest.test_case
            "with_supervised_background cancels child after use failure" `Quick
            test_effect_with_supervised_background_cancels_after_use_failure;
          Alcotest.test_case
            "with_background typed failure cancels use and awaits finalizers"
            `Quick test_effect_with_background_typed_failure_cancels_use;
          Alcotest.test_case
            "with_background defect cancels use and awaits finalizers" `Quick
            test_effect_with_background_defect_cancels_use;
          Alcotest.test_case
            "with_background body success or failure cancels and awaits child"
            `Quick test_effect_with_background_body_exit_cancels_and_awaits;
          Alcotest.test_case
            "with_background body interruption matches par cause shape" `Quick
            test_effect_with_background_body_interruption_matches_par;
          Alcotest.test_case
            "with_supervised_background failure does not cancel use" `Quick
            test_effect_with_supervised_background_failure_does_not_cancel_use;
          Alcotest.test_case
            "with_background same-release publication order chooses one winner"
            `Quick
            test_effect_with_background_same_release_has_one_winner;
          Alcotest.test_case
            "background cleanup after body success matches old shape" `Quick
            test_background_cleanup_after_body_success_matches_old_shape;
          Alcotest.test_case
            "background cleanup after body failure matches old shape" `Quick
            test_background_cleanup_after_body_failure_matches_old_shape;
          Alcotest.test_case
            "background cleanup after body defect matches old shape" `Quick
            test_background_cleanup_after_body_defect_matches_old_shape;
          Alcotest.test_case
            "background loser publishes after cancellation before assembly"
            `Quick
            test_background_loser_publishes_after_cancellation_before_assembly;
          Alcotest.test_case
            "background winner preserves body cleanup failure" `Quick
            test_background_winner_preserves_body_cleanup_failure;
          Alcotest.test_case "threshold failure" `Quick
            test_supervisor_threshold_failure;
          Alcotest.test_case "records multiple failures" `Quick
            test_supervisor_records_multiple_failures;
          Alcotest.test_case "nested scopes compose" `Quick
            test_supervisor_nested_scopes_compose;
        ] );
    ]

  let rec wait_until ?(attempts = 200) label pred =
    if pred () then ()
    else if attempts = 0 then Alcotest.failf "%s did not become true" label
    else (
      B.yield ();
      wait_until ~attempts:(attempts - 1) label pred)

  exception Request_cancel_defect

  (* supcan-stst supcan-f3ww supcan-3sp7 supcan-kptd supcan-0uj5 supcan-vb4t *)
  let test_supervisor_request_cancel_returns_before_settlement () =
    B.with_runtime @@ fun ctx rt ->
    let ready, mark_ready = B.create_promise () in
    let cleanup_started, mark_cleanup_started = B.create_promise () in
    let release_cleanup, release = B.create_promise () in
    let allow_fence, allow = B.create_promise () in
    let request_returned, mark_request_returned = B.create_promise () in
    let child =
      E.acquire_release
        ~acquire:E.unit
        ~release:(fun () ->
          E.sync (fun () -> B.resolve mark_cleanup_started ())
          |> E.bind (fun () -> B.await_effect release_cleanup))
      |> E.bind (fun () ->
             E.sync (fun () -> B.resolve mark_ready ())
             |> E.bind (fun () -> E.never))
    in
    let program =
      Supervisor.scoped {
        run =
          fun sup ->
            let open Supervisor.Scope in
            let* child = start sup (lift child) in
            let* () = lift (B.await_effect ready) in
            let* () = request_cancel child in
            let* () = lift (E.sync (fun () -> B.resolve mark_request_returned ())) in
            let* () = lift (B.await_effect allow_fence) in
            cancel child;
      }
    in
    let result = B.fork_run ctx rt program in
    Fun.protect
      ~finally:(fun () ->
        B.try_resolve allow ();
        B.try_resolve release ())
      (fun () ->
        wait_until "request return" (fun () -> B.is_resolved request_returned);
        wait_until "cleanup start" (fun () -> B.is_resolved cleanup_started);
        Alcotest.(check bool)
          "settlement remains pending" false (B.is_resolved result);
        B.resolve allow ();
        B.yield ();
        Alcotest.(check bool)
          "settlement remains held after fence" false (B.is_resolved result);
        B.resolve release ();
        match B.await result with
        | Exit.Ok () -> ()
        | Exit.Error cause ->
            Alcotest.failf "unexpected request cancellation failure: %a"
              (Cause.pp pp_hidden) cause)

  (* supcan-stst supcan-zqzf supcan-glb2 *)
  let test_supervisor_request_cancel_latches_before_child_start () =
    B.with_runtime @@ fun ctx rt ->
    let start_gate, release_start = B.create_promise () in
    let request_returned, mark_request_returned = B.create_promise () in
    let body_started = ref false in
    let child =
      B.await_effect start_gate
      |> E.bind (fun () -> E.sync (fun () -> body_started := true))
    in
    let program =
      Supervisor.scoped {
        run =
          fun sup ->
            let open Supervisor.Scope in
            let* child = start sup (lift child) in
            let* () = request_cancel child in
            let* () =
              lift (E.sync (fun () -> B.resolve mark_request_returned ()))
            in
            await child;
      }
    in
    let result = B.fork_run ctx rt program in
    Fun.protect ~finally:(fun () -> B.try_resolve release_start ()) (fun () ->
        wait_until "pre-start request return" (fun () ->
            B.is_resolved request_returned);
        wait_until "pre-start child settlement" (fun () -> B.is_resolved result);
        Alcotest.(check bool) "child body did not start" false !body_started;
        match B.await result with
        | Exit.Error (Cause.Interrupt None) -> ()
        | Exit.Error cause ->
            Alcotest.failf "unexpected pre-start cancellation failure: %a"
              (Cause.pp pp_hidden) cause
        | Exit.Ok () -> Alcotest.fail "latched request did not interrupt child")

  (* supcan-3os1 supcan-glb2 supcan-tg7n *)
  let test_supervisor_request_cancel_preserves_terminal_winners () =
    let error_pp fmt = function
      | `Boom -> Format.pp_print_string fmt "Boom"
      | `Cleanup_failed -> Format.pp_print_string fmt "Cleanup_failed"
      | `Failure_not_observed ->
          Format.pp_print_string fmt "Failure_not_observed"
    in
    let late_failure child =
      B.with_runtime @@ fun _ctx rt ->
      let program =
        Supervisor.scoped {
          run =
            fun sup ->
              let open Supervisor.Scope in
              let* child = start sup (lift child) in
              let rec wait_for_failure attempts =
                let* observed = failures sup in
                if observed <> [] then pure ()
                else if attempts = 0 then fail `Failure_not_observed
                else
                  let* () = yield in
                  wait_for_failure (attempts - 1)
              in
              let* () = wait_for_failure 20 in
              let* () = request_cancel child in
              await child;
        }
        |> Eta_observability.with_error_pp error_pp
      in
      B.run rt program
    in
    let completion =
      B.with_runtime @@ fun _ctx rt ->
      let program =
        Supervisor.scoped {
          run =
            fun sup ->
              let open Supervisor.Scope in
              let* child = start sup (pure 42) in
              let* _ = await child in
              let* () = request_cancel child in
              await child;
        }
      in
      B.run rt program
    in
    let typed_failure = late_failure (E.fail `Boom) in
    let defect =
      late_failure (E.sync (fun () -> raise Request_cancel_defect))
    in
    let finalizer_failure =
      late_failure
        (E.acquire_release ~acquire:E.unit
           ~release:(fun () -> E.fail `Cleanup_failed))
    in
    (match completion with
    | Exit.Ok 42 -> ()
    | Exit.Ok value ->
        Alcotest.failf "late request changed completion value to %d" value
    | Exit.Error cause ->
        Alcotest.failf "late request changed completion to %a"
          (Cause.pp pp_hidden) cause);
    (match typed_failure with
    | Exit.Error (Cause.Fail `Boom) -> ()
    | Exit.Error cause ->
        Alcotest.failf "late request changed typed failure to %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok () -> Alcotest.fail "late request changed typed failure to Ok");
    (match defect with
    | Exit.Error (Cause.Die { exn; _ }) when exn == Request_cancel_defect -> ()
    | Exit.Error cause ->
        Alcotest.failf "late request changed defect to %a" (Cause.pp pp_hidden)
          cause
    | Exit.Ok () -> Alcotest.fail "late request changed defect to Ok");
    match finalizer_failure with
    | Exit.Error
        (Cause.Finalizer
          (Cause.Finalizer.Fail
            { error = _; rendered = "Cleanup_failed" })) ->
        ()
    | Exit.Error cause ->
        Alcotest.failf "late request changed finalizer failure to %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok () -> Alcotest.fail "late request changed finalizer failure to Ok"

  (* supcan-3sp7 supcan-dyvd supcan-nnq7 *)
  let test_supervisor_cancel_after_request_preserves_settlement_diagnostics () =
    let late_cancel child =
      B.with_runtime @@ fun _ctx rt ->
      let program =
        Supervisor.scoped {
          run =
            fun sup ->
              let open Supervisor.Scope in
              let* child = start sup (lift child) in
              let rec wait_for_failure attempts =
                let* observed = failures sup in
                if observed <> [] then pure ()
                else if attempts = 0 then fail `Failure_not_observed
                else
                  let* () = yield in
                  wait_for_failure (attempts - 1)
              in
              let* () = wait_for_failure 20 in
              let* () = request_cancel child in
              cancel child;
        }
      in
      B.run rt program
    in
    let run_requested_cleanup ~fails =
      B.with_runtime @@ fun _ctx rt ->
      let ready, mark_ready = B.create_promise () in
      let finalizer_count = ref 0 in
      let release () =
        E.sync (fun () -> incr finalizer_count)
        |> E.bind (fun () -> if fails then E.fail `Cleanup_failed else E.unit)
      in
      let child =
        E.acquire_release ~acquire:E.unit ~release
        |> E.bind (fun () ->
               E.sync (fun () -> B.resolve mark_ready ())
               |> E.bind (fun () -> E.never))
      in
      let program =
        Supervisor.scoped {
          run =
            fun sup ->
              let open Supervisor.Scope in
              let* child = start sup (lift child) in
              let* () = lift (B.await_effect ready) in
              let* () = request_cancel child in
              cancel child;
        }
        |> Eta_observability.with_error_pp (fun fmt -> function
             | `Cleanup_failed -> Format.pp_print_string fmt "Cleanup_failed")
      in
      let exit = B.run rt program in
      (exit, !finalizer_count)
    in
    let clean, clean_finalizers = run_requested_cleanup ~fails:false in
    let cleanup_failure, failed_finalizers =
      run_requested_cleanup ~fails:true
    in
    let typed_failure = late_cancel (E.fail `Boom) in
    let defect = late_cancel (E.sync (fun () -> raise Request_cancel_defect)) in
    (match clean with
    | Exit.Ok () ->
        Alcotest.(check int) "clean finalizer count" 1 clean_finalizers
    | Exit.Error cause ->
        Alcotest.failf "clean request/cancel failed: %a" (Cause.pp pp_hidden)
          cause);
    (match cleanup_failure with
    | Exit.Error
        (Cause.Suppressed
          {
            primary = Cause.Interrupt None;
            finalizer =
              Cause.Finalizer.Fail
                { error = _; rendered = "Cleanup_failed" };
          }) ->
        Alcotest.(check int) "failing finalizer count" 1 failed_finalizers
    | Exit.Error cause ->
        Alcotest.failf "request/cancel changed cleanup diagnostics: %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok () -> Alcotest.fail "request/cancel hid cleanup diagnostics");
    (match typed_failure with
    | Exit.Error (Cause.Fail `Boom) -> ()
    | Exit.Error cause ->
        Alcotest.failf "request/cancel changed typed failure: %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok () -> Alcotest.fail "request/cancel hid typed failure");
    match defect with
    | Exit.Error (Cause.Die { exn; _ }) when exn == Request_cancel_defect -> ()
    | Exit.Error cause ->
        Alcotest.failf "request/cancel changed defect: %a" (Cause.pp pp_hidden)
          cause
    | Exit.Ok () -> Alcotest.fail "request/cancel hid defect"

  (* supcan-eg0p *)
  let test_supervisor_await_after_request_reports_interruption () =
    let late_await child =
      B.with_runtime @@ fun _ctx rt ->
      let program =
        Supervisor.scoped {
          run =
            fun sup ->
              let open Supervisor.Scope in
              let* child = start sup (lift child) in
              let rec wait_for_failure attempts =
                let* observed = failures sup in
                if observed <> [] then pure ()
                else if attempts = 0 then fail `Failure_not_observed
                else
                  let* () = yield in
                  wait_for_failure (attempts - 1)
              in
              let* () = wait_for_failure 20 in
              let* () = request_cancel child in
              await child;
        }
        |> Eta_observability.with_error_pp (fun fmt -> function
             | `Boom -> Format.pp_print_string fmt "Boom"
             | `Cleanup_failed -> Format.pp_print_string fmt "Cleanup_failed"
             | `Failure_not_observed ->
                 Format.pp_print_string fmt "Failure_not_observed")
      in
      B.run rt program
    in
    let completion =
      B.with_runtime @@ fun _ctx rt ->
      B.run rt
        (Supervisor.scoped {
           run =
             fun sup ->
               let open Supervisor.Scope in
               let* child = start sup (pure 42) in
               let* _ = await child in
               let* () = request_cancel child in
               await child;
         })
    in
    let typed_failure = late_await (E.fail `Boom) in
    let defect = late_await (E.sync (fun () -> raise Request_cancel_defect)) in
    let finalizer_failure =
      late_await
        (E.acquire_release ~acquire:E.unit
           ~release:(fun () -> E.fail `Cleanup_failed))
    in
    let interruption =
      B.with_runtime @@ fun _ctx rt ->
      let ready, mark_ready = B.create_promise () in
      let child =
        E.sync (fun () -> B.resolve mark_ready ())
        |> E.bind (fun () -> E.never)
      in
      B.run rt
        (Supervisor.scoped {
           run =
             fun sup ->
               let open Supervisor.Scope in
               let* child = start sup (lift child) in
               let* () = lift (B.await_effect ready) in
               let* () = request_cancel child in
               await child;
         })
    in
    (match completion with
    | Exit.Ok 42 -> ()
    | Exit.Ok value -> Alcotest.failf "await changed completion to %d" value
    | Exit.Error cause ->
        Alcotest.failf "await changed completion to %a" (Cause.pp pp_hidden)
          cause);
    (match typed_failure with
    | Exit.Error (Cause.Fail `Boom) -> ()
    | Exit.Error cause ->
        Alcotest.failf "await changed typed failure to %a" (Cause.pp pp_hidden)
          cause
    | Exit.Ok () -> Alcotest.fail "await hid typed failure");
    (match defect with
    | Exit.Error (Cause.Die { exn; _ }) when exn == Request_cancel_defect -> ()
    | Exit.Error cause ->
        Alcotest.failf "await changed defect to %a" (Cause.pp pp_hidden) cause
    | Exit.Ok () -> Alcotest.fail "await hid defect");
    (match finalizer_failure with
    | Exit.Error
        (Cause.Finalizer
          (Cause.Finalizer.Fail
            { error = _; rendered = "Cleanup_failed" })) ->
        ()
    | Exit.Error cause ->
        Alcotest.failf "await changed finalizer failure to %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok () -> Alcotest.fail "await hid finalizer failure");
    match interruption with
    | Exit.Error (Cause.Interrupt None) -> ()
    | Exit.Error cause ->
        Alcotest.failf "await after request returned %a" (Cause.pp pp_hidden)
          cause
    | Exit.Ok () -> Alcotest.fail "await after request hid interruption"

  (* supcan-6zw9 supcan-urkv supcan-vb4t *)
  let test_supervisor_request_cancel_calls_follow_scope_program_order () =
    B.with_runtime @@ fun _ctx rt ->
    let events = ref [] in
    let mark name = E.sync (fun () -> events := name :: !events) in
    let first_ready, mark_first_ready = B.create_promise () in
    let second_ready, mark_second_ready = B.create_promise () in
    let first_cleanup_started, mark_first_cleanup_started = B.create_promise () in
    let second_cleanup_started, mark_second_cleanup_started = B.create_promise () in
    let release_first_cleanup, release_first = B.create_promise () in
    let release_second_cleanup, release_second = B.create_promise () in
    let second_cleanup_finished, mark_second_cleanup_finished =
      B.create_promise ()
    in
    let replacement_release, release_replacement = B.create_promise () in
    let replacement_started, mark_replacement_started = B.create_promise () in
    let child label ready cleanup_started release_cleanup cleanup_finished =
      E.acquire_release
        ~acquire:E.unit
        ~release:(fun () ->
          mark (label ^ ":cleanup-start")
          |> E.bind (fun () -> E.sync (fun () -> B.resolve cleanup_started ()))
          |> E.bind (fun () -> B.await_effect release_cleanup)
          |> E.bind (fun () -> mark (label ^ ":cleanup-end"))
          |> E.bind cleanup_finished)
      |> E.bind (fun () ->
             mark (label ^ ":ready")
             |> E.bind (fun () -> E.sync (fun () -> B.resolve ready ()))
             |> E.bind (fun () -> E.never))
    in
    let first =
      child "first" mark_first_ready mark_first_cleanup_started
        release_first_cleanup (fun () -> E.unit)
    in
    let second =
      child "second" mark_second_ready mark_second_cleanup_started
        release_second_cleanup (fun () ->
          E.sync (fun () -> B.resolve mark_second_cleanup_finished ()))
    in
    let replacement =
      B.await_effect replacement_release
      |> E.bind (fun () -> mark "replacement:start")
      |> E.bind (fun () ->
             E.sync (fun () -> B.resolve mark_replacement_started ()))
    in
    let program =
      Supervisor.scoped {
        run =
          fun sup ->
            let open Supervisor.Scope in
            let* first_child = start sup (lift first) in
            let* second_child = start sup (lift second) in
            let* replacement_child = start sup (lift replacement) in
            let* () = lift (B.await_effect first_ready) in
            let* () = lift (B.await_effect second_ready) in
            let* () = lift (mark "request:first-call") in
            let* () = request_cancel first_child in
            let* () = lift (mark "request:first-return") in
            let* () = lift (mark "request:second-call") in
            let* () = request_cancel second_child in
            let* () = lift (mark "request:second-return") in
            let* () =
              lift (E.sync (fun () -> B.resolve release_replacement ()))
            in
            let* () = lift (B.await_effect replacement_started) in
            let* () = lift (B.await_effect first_cleanup_started) in
            let* () = lift (B.await_effect second_cleanup_started) in
            let* () = lift (E.sync (fun () -> B.resolve release_second ())) in
            let* () = lift (B.await_effect second_cleanup_finished) in
            let* () = lift (E.sync (fun () -> B.resolve release_first ())) in
            let* () = cancel first_child in
            let* () = cancel second_child in
            let* () = await replacement_child in
            pure (List.rev !events);
      }
    in
    let events = run_ok rt program in
    let expected_events =
      [
        "first:ready";
        "second:ready";
        "request:first-call";
        "request:first-return";
        "request:second-call";
        "request:second-return";
        "first:cleanup-start";
        "second:cleanup-start";
        "replacement:start";
        "second:cleanup-end";
        "first:cleanup-end";
      ]
    in
    Alcotest.(check int)
      "exact event count" (List.length expected_events) (List.length events);
    List.iter
      (fun expected ->
        Alcotest.(check int)
          ("one " ^ expected) 1
          (List.length (List.filter (String.equal expected) events)))
      expected_events;
    let request_events =
      List.filter (String.starts_with ~prefix:"request:") events
    in
    Alcotest.(check (list string))
      "exact request event sequence"
      [
        "request:first-call";
        "request:first-return";
        "request:second-call";
        "request:second-return";
      ]
      request_events;
    let position name =
      match List.find_index (String.equal name) events with
      | Some index -> index
      | None -> Alcotest.failf "missing supervisor event %s" name
    in
    let before left right =
      Alcotest.(check bool)
        (left ^ " before " ^ right) true
        (position left < position right)
    in
    before "request:first-call" "request:first-return";
    before "request:first-return" "request:second-call";
    before "request:second-call" "request:second-return";
    before "request:second-return" "replacement:start";
    before "replacement:start" "second:cleanup-end";
    before "second:cleanup-end" "first:cleanup-end"

  let request_cancel_tests =
    [
      ( "Supervisor request cancellation",
        [
          Alcotest.test_case "request_cancel returns before settlement" `Quick
            test_supervisor_request_cancel_returns_before_settlement;
          Alcotest.test_case "request_cancel latches before child start" `Quick
            test_supervisor_request_cancel_latches_before_child_start;
          Alcotest.test_case "request_cancel preserves terminal winners" `Quick
            test_supervisor_request_cancel_preserves_terminal_winners;
          Alcotest.test_case
            "cancel after request_cancel preserves settlement diagnostics" `Quick
            test_supervisor_cancel_after_request_preserves_settlement_diagnostics;
          Alcotest.test_case "await after request_cancel reports interruption"
            `Quick test_supervisor_await_after_request_reports_interruption;
          Alcotest.test_case
            "request_cancel calls follow scope program order" `Quick
            test_supervisor_request_cancel_calls_follow_scope_program_order;
        ] );
    ]

  let cancellation_matches contract expected exn =
    match contract.Runtime_contract.cancellation_reason exn with
    | Some actual -> actual == expected
    | None -> exn == expected

  let rec contract_wait_until contract attempts predicate =
    if predicate () then true
    else if attempts = 0 then false
    else (
      contract.Runtime_contract.yield ();
      contract_wait_until contract (attempts - 1) predicate)

  (* supcan-kptd *)
  let test_runtime_cancel_records_request_and_returns_before_settlement () =
    B.with_runtime_contract @@ fun _ctx contract ->
    let reason = Failure "runtime cancel probe" in
    let cleanup_started = ref false in
    let cleanup_finished = ref false in
    let finalizer_count = ref 0 in
    let reason_observed = ref false in
    let #(cancel_ready, publish_cancel) =
      contract.Runtime_contract.create_promise () in
    let #(release_cleanup, release) =
      contract.Runtime_contract.create_promise () in
    let returned_before_settlement, cleanup_was_pending =
      contract.Runtime_contract.run_scope @@ fun sw ->
      contract.Runtime_contract.fork sw (fun () ->
          try
            contract.Runtime_contract.cancel_sub @@ fun cancel_context ->
            contract.Runtime_contract.resolve_promise publish_cancel
              cancel_context;
            Fun.protect
              ~finally:(fun () ->
                try
                  contract.Runtime_contract.protect @@ fun () ->
                  cleanup_started := true;
                  incr finalizer_count;
                  contract.Runtime_contract.await_promise release_cleanup;
                  cleanup_finished := true
                with exn ->
                  if not (cancellation_matches contract reason exn) then
                    raise exn)
              (fun () -> contract.Runtime_contract.await_cancel ())
          with exn ->
            if cancellation_matches contract reason exn then
              reason_observed := true
            else raise exn);
      let cancel_context =
        contract.Runtime_contract.await_promise cancel_ready
      in
      contract.Runtime_contract.cancel cancel_context reason;
      let returned_before_settlement = not !cleanup_finished in
      let cleanup_started_before_fallback =
        contract_wait_until contract 200 (fun () -> !cleanup_started)
      in
      if not cleanup_started_before_fallback then (
        contract.Runtime_contract.resolve_promise release ();
        Alcotest.fail "Runtime_contract.cancel did not record cancellation");
      let cleanup_was_pending = not !cleanup_finished in
      contract.Runtime_contract.resolve_promise release ();
      (returned_before_settlement, cleanup_was_pending)
    in
    Alcotest.(check bool)
      "cancel returned before settlement" true returned_before_settlement;
    Alcotest.(check bool)
      "cleanup remained pending after cancel" true cleanup_was_pending;
    Alcotest.(check bool) "cancel reason observed" true !reason_observed;
    Alcotest.(check bool) "cleanup finished" true !cleanup_finished;
    Alcotest.(check int) "one finalizer" 1 !finalizer_count

  (* supcan-0uj5 *)
  let test_runtime_fail_scope_records_failure_and_returns_before_settlement () =
    B.with_runtime_contract @@ fun _ctx contract ->
    let reason = Failure "runtime fail_scope probe" in
    let fallback = Failure "runtime fail_scope fallback" in
    let cleanup_started = ref false in
    let cleanup_finished = ref false in
    let finalizer_count = ref 0 in
    let reason_observed = ref false in
    let #(target_ready, publish_target) =
      contract.Runtime_contract.create_promise () in
    let #(child_ready, publish_child) =
      contract.Runtime_contract.create_promise () in
    let #(target_done, publish_target_done) =
      contract.Runtime_contract.create_promise ()
    in
    let #(release_cleanup, release) =
      contract.Runtime_contract.create_promise () in
    let #(release_body, release_target_body) =
      contract.Runtime_contract.create_promise ()
    in
    let returned_before_settlement, cleanup_was_pending, cleanup_started_in_time,
        failure_recorded =
      contract.Runtime_contract.run_scope @@ fun outer_sw ->
      contract.Runtime_contract.fork outer_sw (fun () ->
          let recorded =
            try
              contract.Runtime_contract.run_scope @@ fun target_sw ->
              contract.Runtime_contract.resolve_promise publish_target target_sw;
              contract.Runtime_contract.fork target_sw (fun () ->
                  try
                    contract.Runtime_contract.cancel_sub @@ fun cancel_context ->
                    contract.Runtime_contract.resolve_promise publish_child
                      cancel_context;
                    Fun.protect
                      ~finally:(fun () ->
                        try
                          contract.Runtime_contract.protect @@ fun () ->
                          cleanup_started := true;
                          incr finalizer_count;
                          contract.Runtime_contract.await_promise release_cleanup;
                          cleanup_finished := true
                        with exn ->
                          if
                            not
                              (cancellation_matches contract reason exn
                              || cancellation_matches contract fallback exn)
                          then raise exn)
                      (fun () -> contract.Runtime_contract.await_cancel ())
                  with exn ->
                    if cancellation_matches contract reason exn then
                      reason_observed := true
                    else if not (cancellation_matches contract fallback exn) then
                      raise exn);
              contract.Runtime_contract.await_promise release_body;
              false
            with exn when exn == reason -> true
          in
          contract.Runtime_contract.resolve_promise publish_target_done recorded);
      let target_scope =
        contract.Runtime_contract.await_promise target_ready
      in
      let child_context =
        contract.Runtime_contract.await_promise child_ready
      in
      contract.Runtime_contract.fail_scope target_scope reason;
      let returned_before_settlement = not !cleanup_finished in
      let cleanup_started_in_time =
        contract_wait_until contract 200 (fun () -> !cleanup_started)
      in
      let cleanup_was_pending = not !cleanup_finished in
      contract.Runtime_contract.resolve_promise release ();
      if not cleanup_started_in_time then (
        contract.Runtime_contract.cancel child_context fallback;
        contract.Runtime_contract.resolve_promise release_target_body ());
      let failure_recorded =
        contract.Runtime_contract.await_promise target_done
      in
      ( returned_before_settlement,
        cleanup_was_pending,
        cleanup_started_in_time,
        failure_recorded )
    in
    Alcotest.(check bool)
      "fail_scope returned before settlement" true returned_before_settlement;
    Alcotest.(check bool)
      "cleanup remained pending after fail_scope" true cleanup_was_pending;
    Alcotest.(check bool)
      "fail_scope requested cancellation" true cleanup_started_in_time;
    Alcotest.(check bool) "scope failure recorded" true failure_recorded;
    Alcotest.(check bool) "scope reason observed" true !reason_observed;
    Alcotest.(check bool) "cleanup finished" true !cleanup_finished;
    Alcotest.(check int) "one finalizer" 1 !finalizer_count

  let runtime_contract_request_tests =
    [
      ( "Runtime contract request operations",
        [
          Alcotest.test_case
            "runtime cancel records request and returns before settlement" `Quick
            test_runtime_cancel_records_request_and_returns_before_settlement;
          Alcotest.test_case
            "runtime fail_scope records failure and returns before settlement"
            `Quick
            test_runtime_fail_scope_records_failure_and_returns_before_settlement;
        ] );
    ]

  let tests = tests @ request_cancel_tests @ runtime_contract_request_tests
end
