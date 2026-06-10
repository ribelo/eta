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
    | Cause.Finalizer.Fail actual -> String.equal expected actual
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
    let render = function `Cleanup_failed -> "rendered cleanup" in
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
      |> E.with_error_renderer render
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
        ~acquire:(E.named "supervisor.acquire" (E.sync (fun () -> ())))
        ~release:(fun () ->
          E.named "supervisor.release"
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
        ~acquire:(E.named "supervisor.acquire" (E.sync (fun () -> ())))
        ~release:(fun () ->
          E.named "supervisor.release"
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

  let test_effect_with_background_cancels_child () =
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
      E.with_background background (fun () ->
          wait_for_sleepers_effect clock 1
          |> E.map (fun () -> !child_started))
    in
    match B.run rt program with
    | Exit.Ok true -> Alcotest.(check bool) "finalizer ran" true !finalizer_ran
    | Exit.Ok false -> Alcotest.fail "background did not start"
    | Exit.Error cause ->
        Alcotest.failf "unexpected with_background failure: %a"
          (Cause.pp pp_hidden) cause

  let test_effect_with_background_reports_child_cleanup_failure () =
    B.with_test_clock @@ fun _ctx clock rt ->
    let child_started = ref false in
    let background =
      E.acquire_release
        ~acquire:(E.sync (fun () -> child_started := true))
        ~release:(fun () -> E.fail `Cleanup_failed)
      |> E.bind (fun () -> E.delay (Duration.ms 1_000) E.unit)
    in
    let program =
      E.with_background background (fun () ->
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
          Alcotest.test_case "with_background cancels child" `Quick
            test_effect_with_background_cancels_child;
          Alcotest.test_case "with_background reports cleanup failure" `Quick
            test_effect_with_background_reports_child_cleanup_failure;
          Alcotest.test_case "threshold failure" `Quick
            test_supervisor_threshold_failure;
          Alcotest.test_case "records multiple failures" `Quick
            test_supervisor_records_multiple_failures;
          Alcotest.test_case "nested scopes compose" `Quick
            test_supervisor_nested_scopes_compose;
        ] );
    ]
end
