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

  let rec wait_until ?(attempts = 200) label pred =
    if pred () then ()
    else if attempts = 0 then Alcotest.failf "%s did not become true" label
    else (
      B.yield ();
      wait_until ~attempts:(attempts - 1) label pred)

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

  (* supcan-stst supcan-f3ww supcan-3sp7 supcan-kptd supcan-0uj5 supcan-vb4t *)
  let test_supervisor_request_cancel_returns_before_settlement () =
    B.with_runtime @@ fun ctx rt ->
    let ready, mark_ready = B.create_promise () in
    let cleanup_started, mark_cleanup_started = B.create_promise () in
    let release_cleanup, release = B.create_promise () in
    let request_returned, mark_request_returned = B.create_promise () in
    let child =
      E.acquire_release
        ~acquire:(E.sync (fun () -> B.resolve mark_ready ()))
        ~release:(fun () ->
          E.sync (fun () -> B.resolve mark_cleanup_started ())
          |> E.bind (fun () -> B.await_effect release_cleanup))
      |> E.bind (fun () -> E.never)
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
            cancel child;
      }
    in
    let result = B.fork_run ctx rt program in
    wait_until "request return" (fun () -> B.is_resolved request_returned);
    wait_until "cleanup start" (fun () -> B.is_resolved cleanup_started);
    Alcotest.(check bool) "settlement remains pending" false (B.is_resolved result);
    B.resolve release ();
    match B.await result with
    | Exit.Ok () -> ()
    | Exit.Error cause ->
        Alcotest.failf "unexpected request cancellation failure: %a"
          (Cause.pp pp_hidden) cause

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
          Alcotest.test_case "request_cancel returns before settlement" `Quick
            test_supervisor_request_cancel_returns_before_settlement;
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
end
