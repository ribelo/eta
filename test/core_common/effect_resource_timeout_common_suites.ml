module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  open Eta

  module E = Effect

  let pp_hidden ppf _ = Format.pp_print_string ppf "<effect>"

  let runtime_interrupt_effect () =
    E.Expert.make ~capabilities:[ `Concurrency ] ~leaf_name:"test.interrupt"
    @@ fun context ->
    let contract = E.Expert.contract context in
    contract.Eta.Runtime_contract.cancel_sub @@ fun cancel_context ->
    contract.Eta.Runtime_contract.cancel cancel_context Exit;
    contract.Eta.Runtime_contract.await_cancel ()

  let run_ok rt eff =
    match B.run rt eff with
    | Exit.Ok value -> value
    | Exit.Error cause ->
        Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause

  let check_exit_ok testable label expected = function
    | Exit.Ok actual -> Alcotest.check testable label expected actual
    | Exit.Error cause ->
        Alcotest.failf "%s: expected Ok, got %a" label
          (Cause.pp pp_hidden) cause

  let check_exit_error testable label expected = function
    | Exit.Error actual -> Alcotest.check testable label expected actual
    | Exit.Ok _ -> Alcotest.failf "%s: expected Error" label

  let string_cause =
    Alcotest.testable (Cause.pp Format.pp_print_string) (Cause.equal String.equal)

  let rec finalizer_contains expected = function
    | Cause.Finalizer.Fail { error = _; rendered } -> String.equal expected rendered
    | Cause.Finalizer.Die _ | Cause.Finalizer.Interrupt _ -> false
    | Cause.Finalizer.Sequential causes | Cause.Finalizer.Concurrent causes ->
        List.exists (finalizer_contains expected) causes
    | Cause.Finalizer.Finalizer cause -> finalizer_contains expected cause
    | Cause.Finalizer.Suppressed { primary; finalizer } ->
        finalizer_contains expected primary || finalizer_contains expected finalizer

  let rec cause_finalizer_contains expected = function
    | Cause.Fail _ | Cause.Die _ | Cause.Interrupt _ -> false
    | Cause.Sequential causes | Cause.Concurrent causes ->
        List.exists (cause_finalizer_contains expected) causes
    | Cause.Finalizer finalizer -> finalizer_contains expected finalizer
    | Cause.Suppressed { primary; finalizer } ->
        cause_finalizer_contains expected primary
        || finalizer_contains expected finalizer

  let rec typed_timeout_cause_contains_body_failure = function
    | Cause.Fail `Body -> true
    | Cause.Fail (`Slow | `Inner | `Outer) | Cause.Die _ | Cause.Interrupt _ ->
        false
    | Cause.Sequential causes | Cause.Concurrent causes ->
        List.exists typed_timeout_cause_contains_body_failure causes
    | Cause.Finalizer _ -> false
    | Cause.Suppressed { primary; finalizer = _ } ->
        typed_timeout_cause_contains_body_failure primary

  let rec timeout_finalizer_cause_contains_slow = function
    | Cause.Fail `Slow -> true
    | Cause.Fail `Release | Cause.Die _ | Cause.Interrupt _ -> false
    | Cause.Sequential causes | Cause.Concurrent causes ->
        List.exists timeout_finalizer_cause_contains_slow causes
    | Cause.Finalizer _ -> false
    | Cause.Suppressed { primary; finalizer = _ } ->
        timeout_finalizer_cause_contains_slow primary

  let wait_until ?(attempts = 200) pred =
    let rec loop n =
      if pred () then ()
      else if n = 0 then Alcotest.fail "condition did not become true"
      else (
        B.yield ();
        loop (n - 1))
    in
    loop attempts

  let wait_for_sleepers clock expected =
    wait_until (fun () -> B.sleeper_count clock >= expected)

  let mark trail name =
    E.named name (E.sync (fun () -> trail := name :: !trail))

  let test_acquire_release () =
    B.with_runtime @@ fun _ctx rt ->
    let trail = ref [] in
    let eff =
      E.with_scope
        (E.acquire_release
           ~acquire:(mark trail "acquired" |> E.map (fun () -> 1))
           ~release:(fun _ -> mark trail "released")
        |> E.bind (fun _ -> mark trail "body"))
    in
    run_ok rt eff;
    Alcotest.(check (list string))
      "ordering" [ "acquired"; "body"; "released" ] (List.rev !trail)

  let test_acquire_release_root_scope_runs_finalizer () =
    B.with_runtime @@ fun _ctx rt ->
    let released = ref false in
    let eff =
      E.acquire_release ~acquire:E.unit
        ~release:(fun () -> E.sync (fun () -> released := true))
    in
    run_ok rt eff;
    Alcotest.(check bool) "released" true !released

  let test_acquire_release_root_scope_runs_finalizer_on_failure () =
    B.with_runtime @@ fun _ctx rt ->
    let released = ref false in
    let eff =
      E.acquire_release ~acquire:E.unit
        ~release:(fun () -> E.sync (fun () -> released := true))
      |> E.bind (fun () -> E.fail `Boom)
    in
    (match B.run rt eff with
    | Exit.Error (Cause.Fail `Boom) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected typed failure, got %a"
          (Cause.pp (fun fmt `Boom -> Format.pp_print_string fmt "Boom"))
          cause
    | Exit.Ok () -> Alcotest.fail "expected typed failure");
    Alcotest.(check bool) "released" true !released

  let test_daemon_drain_waits_for_pending_finalizer () =
    B.with_runtime @@ fun _ctx rt ->
    let started, started_resolver = B.create_promise () in
    let release, release_resolver = B.create_promise () in
    let completed = Atomic.make false in
    let released = Atomic.make false in
    let daemon_body =
      E.acquire_release ~acquire:E.unit
        ~release:(fun () -> E.sync (fun () -> Atomic.set released true))
      |> E.bind (fun () ->
             E.sync (fun () -> B.resolve started_resolver ())
             |> E.bind (fun () -> B.await_effect release)
             |> E.bind (fun () ->
                    E.sync (fun () -> Atomic.set completed true)))
    in
    run_ok rt (E.daemon daemon_body);
    ignore (B.await started : unit);
    Alcotest.(check bool) "daemon pending" false (Atomic.get completed);
    Alcotest.(check bool) "finalizer pending" false (Atomic.get released);
    B.resolve release_resolver ();
    Alcotest.(check bool) "work pending before drain" false (Atomic.get completed);
    B.drain rt;
    Alcotest.(check bool) "daemon completed" true (Atomic.get completed);
    Alcotest.(check bool) "released" true (Atomic.get released)

  let test_daemon_failure_logs_diagnostic () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let daemon_body = E.sync (fun () -> failwith "daemon crash") in
    run_ok rt (E.daemon daemon_body);
    B.drain rt;
    match Logger.dump logger with
    | [ record ] ->
        Alcotest.(check bool) "level" true (record.level = Logger.Error);
        Alcotest.(check string) "body" "eta.daemon.failure" record.body;
        Alcotest.(check (option string))
          "exception message" (Some "Failure(\"daemon crash\")")
          (List.assoc_opt "exception.message" record.attrs)
    | records ->
        Alcotest.failf "expected one daemon diagnostic, got %d"
          (List.length records)

  let test_daemon_interrupt_does_not_log_diagnostic () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    run_ok rt (E.daemon (runtime_interrupt_effect ()));
    B.drain rt;
    Alcotest.(check int)
      "no daemon diagnostics" 0
      (List.length (Logger.dump logger))

  let test_acquire_release_on_failure () =
    B.with_runtime @@ fun _ctx rt ->
    let trail = ref [] in
    let eff =
      E.with_scope
        (E.acquire_release ~acquire:(mark trail "acq") ~release:(fun () ->
             mark trail "rel")
        |> E.bind (fun () -> E.fail `Boom)
        |> E.bind_error (fun (`Boom : [ `Boom ]) -> mark trail "caught"))
    in
    run_ok rt eff;
    Alcotest.(check (list string))
      "release after recovered body failure"
      [ "acq"; "caught"; "rel" ] (List.rev !trail)

  let test_acquire_release_suppresses_release_failure () =
    B.with_runtime @@ fun _ctx rt ->
    let eff =
      E.with_scope
        (E.acquire_release ~acquire:(E.pure ())
           ~release:(fun () -> E.fail "release")
        |> E.bind (fun () -> E.fail "body"))
    in
    match B.run rt eff with
    | Exit.Error
        (Cause.Suppressed
          {
            primary = Cause.Fail "body";
            finalizer = Cause.Finalizer.Fail { error = _; rendered };
          }) when String.equal rendered "<typed failure>" ->
        ()
    | Exit.Error cause ->
        Alcotest.failf "expected suppressed release failure, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok () -> Alcotest.fail "expected suppressed release failure"

  let test_acquire_release_release_failure_after_success () =
    B.with_runtime @@ fun _ctx rt ->
    let eff =
      E.with_scope
        (E.acquire_release ~acquire:(E.pure ())
           ~release:(fun () -> E.fail "release")
        |> E.bind (fun () -> E.pure "body"))
    in
    check_exit_error string_cause "release failure"
      (Cause.Finalizer (Cause.Finalizer.Fail { error = "<typed failure>"; rendered = "<typed failure>" }))
      (B.run rt eff)

  let test_acquire_release_releases_on_defect () =
    B.with_runtime @@ fun _ctx rt ->
    let released = ref false in
    let eff =
      E.with_scope
        (E.acquire_release ~acquire:(E.pure ())
           ~release:(fun () -> E.sync (fun () -> released := true))
        |> E.bind (fun () -> E.sync (fun () -> failwith "body defect")))
    in
    (match B.run rt eff with
    | Exit.Error (Cause.Die _) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected body defect, got %a"
          (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
          cause
    | Exit.Ok _ -> Alcotest.fail "expected body defect");
    Alcotest.(check bool) "released" true !released

  let test_acquire_release_suppresses_release_failure_after_defect () =
    B.with_runtime @@ fun _ctx rt ->
    let eff =
      E.with_scope
        (E.acquire_release ~acquire:(E.pure ())
           ~release:(fun () -> E.fail "release")
        |> E.bind (fun () -> E.sync (fun () -> failwith "body defect")))
    in
    match B.run rt eff with
    | Exit.Error
        (Cause.Suppressed
          { primary = Cause.Die _; finalizer = Cause.Finalizer.Fail { error = _; rendered } })
      when String.equal rendered "<typed failure>" ->
        ()
    | Exit.Error cause ->
        Alcotest.failf "expected suppressed release failure after defect, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "expected suppressed release failure after defect"

  let test_acquire_use_release_success () =
    B.with_runtime @@ fun _ctx rt ->
    let trail = ref [] in
    let eff =
      E.with_scope
        (E.acquire_use_release
           ~acquire:(mark trail "acquired" |> E.map (fun () -> 1))
           ~release:(fun resource ->
             mark trail ("released:" ^ string_of_int resource))
           (fun resource ->
             let open Syntax in
             let@ value = fun k -> k resource in
             mark trail ("body:" ^ string_of_int value)
             |> E.map (fun () -> value + 1)))
    in
    Alcotest.(check int) "body result" 2 (run_ok rt eff);
    Alcotest.(check (list string))
      "ordering"
      [ "acquired"; "body:1"; "released:1" ]
      (List.rev !trail)

  let test_acquire_use_release_is_lexical_bracket () =
    B.with_runtime @@ fun _ctx rt ->
    let active = ref 0 in
    let max_active = ref 0 in
    let acquire =
      E.sync (fun () ->
          incr active;
          max_active := max !max_active !active;
          ())
    in
    let release () = E.sync (fun () -> decr active) in
    let one =
      E.acquire_use_release ~acquire ~release (fun () ->
          E.sync (fun () ->
              Alcotest.(check int) "active inside body" 1 !active))
    in
    run_ok rt (E.concat [ one; one; one ]);
    Alcotest.(check int) "released after each body" 0 !active;
    Alcotest.(check int) "no accumulated resources" 1 !max_active

  let test_acquire_use_release_typed_failure_releases () =
    B.with_runtime @@ fun _ctx rt ->
    let released = ref false in
    let eff =
      E.with_scope
        (E.acquire_use_release ~acquire:(E.pure "resource")
           ~release:(fun _ -> E.sync (fun () -> released := true))
           (fun _ -> E.fail `Boom))
    in
    (match B.run rt eff with
    | Exit.Error (Cause.Fail `Boom) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected typed failure, got %a"
          (Cause.pp (fun fmt `Boom -> Format.pp_print_string fmt "Boom"))
          cause
    | Exit.Ok _ -> Alcotest.fail "expected typed failure");
    Alcotest.(check bool) "released" true !released

  let test_acquire_use_release_defect_releases () =
    B.with_runtime @@ fun _ctx rt ->
    let released = ref false in
    let eff =
      E.with_scope
        (E.acquire_use_release ~acquire:(E.pure "resource")
           ~release:(fun _ -> E.sync (fun () -> released := true))
           (fun _ -> E.sync (fun () -> failwith "body defect")))
    in
    (match B.run rt eff with
    | Exit.Error (Cause.Die _) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected body defect, got %a"
          (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
          cause
    | Exit.Ok _ -> Alcotest.fail "expected body defect");
    Alcotest.(check bool) "released" true !released

  let test_acquire_use_release_suppresses_release_failure_after_defect () =
    B.with_runtime @@ fun _ctx rt ->
    let eff =
      E.with_scope
        (E.acquire_use_release ~acquire:(E.pure ())
           ~release:(fun () -> E.fail "release")
           (fun () -> E.sync (fun () -> failwith "body defect")))
    in
    match B.run rt eff with
    | Exit.Error
        (Cause.Suppressed
          { primary = Cause.Die _; finalizer = Cause.Finalizer.Fail { error = _; rendered } })
      when String.equal rendered "<typed failure>" ->
        ()
    | Exit.Error cause ->
        Alcotest.failf "expected suppressed release failure after defect, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "expected suppressed release failure after defect"

  let test_acquire_use_release_releases_on_cancel () =
    B.with_test_clock @@ fun ctx clock rt ->
    let released = ref 0 in
    let acquired, acquired_u = B.create_promise () in
    let slow =
      E.with_scope
        (E.acquire_use_release
           ~acquire:
             (E.named "acquire_use_release.acquire.cancelled"
                (E.sync (fun () -> B.resolve acquired_u ())))
           ~release:(fun () ->
             E.named "acquire_use_release.release.cancelled"
               (E.sync (fun () -> incr released)))
           (fun () -> E.pure "slow" |> E.delay (Duration.seconds 10)))
    in
    let fast =
      E.named "wait-acquire-use-release-acquired" (B.await_effect acquired)
      |> E.map (fun () -> "fast")
    in
    let promise = B.fork_run ctx rt (E.race [ slow; fast ]) in
    wait_for_sleepers clock 1;
    check_exit_ok Alcotest.string "fast wins" "fast" (B.await promise);
    Alcotest.(check int) "cancelled release once" 1 !released

  let test_acquire_use_release_release_failure_after_success () =
    B.with_runtime @@ fun _ctx rt ->
    let eff =
      E.with_scope
        (E.acquire_use_release ~acquire:(E.pure ())
           ~release:(fun () -> E.fail "release")
           (fun () -> E.pure "body"))
    in
    check_exit_error string_cause "release failure"
      (Cause.Finalizer (Cause.Finalizer.Fail { error = "<typed failure>"; rendered = "<typed failure>" }))
      (B.run rt eff)

  let test_with_resource_let_at_success () =
    B.with_runtime @@ fun _ctx rt ->
    let trail = ref [] in
    let eff =
      let open Syntax in
      let@ resource =
        E.with_resource
          ~acquire:(mark trail "acquired" |> E.map (fun () -> 1))
          ~release:(fun resource ->
            mark trail ("released:" ^ string_of_int resource))
      in
      mark trail ("body:" ^ string_of_int resource)
      |> E.map (fun () -> resource + 1)
    in
    Alcotest.(check int) "body result" 2 (run_ok rt eff);
    Alcotest.(check (list string))
      "ordering"
      [ "acquired"; "body:1"; "released:1" ]
      (List.rev !trail)

  let update_max cell value =
    let rec loop () =
      let current = Atomic.get cell in
      if value > current && not (Atomic.compare_and_set cell current value) then
        loop ()
    in
    loop ()

  let test_acquire_all_par_admission_and_concurrency () =
    B.with_runtime @@ fun ctx rt ->
    let run ?max_concurrent ~expected_bound count =
      let gate, gate_u = B.create_promise () in
      let active = Atomic.make 0 in
      let max_active = Atomic.make 0 in
      let acquire value =
        E.sync (fun () ->
            let now = Atomic.fetch_and_add active 1 + 1 in
            update_max max_active now)
        |> E.bind (fun () -> B.await_effect gate)
        |> E.bind (fun () ->
               E.sync (fun () ->
                   ignore (Atomic.fetch_and_add active (-1));
                   value))
      in
      let configs = List.init count Fun.id in
      let eff =
        match max_concurrent with
        | None -> E.acquire_all_par ~acquire ~release:(fun _ -> E.unit) configs
        | Some max_concurrent ->
            E.acquire_all_par ~max_concurrent ~acquire
              ~release:(fun _ -> E.unit) configs
      in
      let fiber = B.fork_run ctx rt (E.with_scope eff) in
      wait_until (fun () -> Atomic.get active = expected_bound);
      Alcotest.(check int)
        "admission reaches bound" expected_bound (Atomic.get max_active);
      B.resolve gate_u ();
      check_exit_ok Alcotest.(list int) "all results" configs (B.await fiber);
      Alcotest.(check int) "all acquisitions finished" 0 (Atomic.get active)
    in
    run ~expected_bound:8 10;
    run ~max_concurrent:3 ~expected_bound:3 7;
    match
      E.acquire_all_par ~max_concurrent:0 ~acquire:E.pure
        ~release:(fun _ -> E.unit) []
    with
    | exception Invalid_argument _ -> ()
    | _ -> Alcotest.fail "expected nonpositive max_concurrent rejection"

  let test_acquire_all_par_failure_releases_reverse_success_order () =
    B.with_runtime @@ fun _ctx rt ->
    let a_done, a_done_u = B.create_promise () in
    let b_done, b_done_u = B.create_promise () in
    let d_started, d_started_u = B.create_promise () in
    let releases = ref [] in
    let d_cancelled = ref false in
    let acquire = function
      | `A ->
          E.sync (fun () ->
              B.resolve a_done_u ();
              "a")
      | `B ->
          B.await_effect a_done
          |> E.bind (fun () ->
                 E.sync (fun () ->
                     B.resolve b_done_u ();
                     "b"))
      | `Fail ->
          B.await_effect b_done
          |> E.bind (fun () -> B.await_effect d_started)
          |> E.bind (fun () -> E.fail `Acquire)
      | `In_flight ->
          E.sync (fun () -> B.resolve d_started_u ())
          |> E.bind (fun () -> B.await_cancel_effect ())
          |> E.on_interrupt (fun _ ->
                 E.sync (fun () -> d_cancelled := true))
          |> E.map (fun () -> "never")
    in
    let release resource =
      E.sync (fun () -> releases := resource :: !releases)
    in
    let eff =
      E.with_scope
        (E.acquire_all_par ~acquire ~release [ `A; `B; `Fail; `In_flight ])
    in
    (match B.run rt eff with
    | Exit.Error (Cause.Fail `Acquire) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected acquire failure, got %a" (Cause.pp pp_hidden)
          cause
    | Exit.Ok _ -> Alcotest.fail "expected acquire failure");
    Alcotest.(check (list string))
      "reverse successful-acquisition order" [ "b"; "a" ]
      (List.rev !releases);
    Alcotest.(check bool) "in-flight acquire cancelled" true !d_cancelled

  let test_acquire_all_par_parent_interruption_rolls_back_once () =
    B.with_runtime @@ fun ctx rt ->
    let a_done, a_done_u = B.create_promise () in
    let b_done, b_done_u = B.create_promise () in
    let c_started, c_started_u = B.create_promise () in
    let releases = ref [] in
    let acquire = function
      | `A ->
          E.sync (fun () ->
              B.resolve a_done_u ();
              "a")
      | `B ->
          B.await_effect a_done
          |> E.bind (fun () ->
                 E.sync (fun () ->
                     B.resolve b_done_u ();
                     "b"))
      | `In_flight ->
          B.await_effect b_done
          |> E.bind (fun () ->
                 E.sync (fun () -> B.resolve c_started_u ()))
          |> E.bind (fun () -> B.await_cancel_effect ())
          |> E.map (fun () -> "never")
    in
    let release resource =
      E.sync (fun () -> releases := resource :: !releases)
    in
    let fiber =
      B.fork_run_cancelable ctx rt
        (E.with_scope
           (E.acquire_all_par ~acquire ~release [ `A; `B; `In_flight ]))
    in
    ignore (B.await c_started : unit);
    B.cancel_fiber fiber;
    (match B.await_cancelable fiber with
    | `Cancelled -> ()
    | `Returned (Exit.Error cause) when Cause.is_interrupt_only cause -> ()
    | `Returned (Exit.Error cause) ->
        Alcotest.failf "expected parent interruption, got %a"
          (Cause.pp pp_hidden) cause
    | `Returned (Exit.Ok _) -> Alcotest.fail "parent cancellation returned Ok");
    Alcotest.(check (list string))
      "parent interruption reverse rollback exactly once" [ "b"; "a" ]
      (List.rev !releases)

  let test_acquire_all_par_rollback_release_failure_diagnostics () =
    B.with_runtime @@ fun _ctx rt ->
    let a_done, a_done_u = B.create_promise () in
    let releases = ref 0 in
    let acquire = function
      | `A ->
          E.sync (fun () ->
              B.resolve a_done_u ();
              "a")
      | `Fail ->
          B.await_effect a_done |> E.bind (fun () -> E.fail `Acquire)
    in
    let release _resource =
      E.sync (fun () -> incr releases)
      |> E.bind (fun () -> E.fail `Release)
    in
    (match
       B.run rt
         (E.with_scope
            (E.acquire_all_par ~acquire ~release [ `A; `Fail ]))
     with
    | Exit.Error
        (Cause.Suppressed
          {
            primary = Cause.Fail `Acquire;
            finalizer = Cause.Finalizer.Fail { error = _; rendered };
          }) when String.equal rendered "<typed failure>" ->
        ()
    | Exit.Error cause ->
        Alcotest.failf "expected acquire failure with rollback diagnostic, got %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected acquire and rollback failure");
    Alcotest.(check int) "failing staged release ran once" 1 !releases

  let test_acquire_all_par_acquire_defect_rolls_back () =
    B.with_runtime @@ fun _ctx rt ->
    let a_done, a_done_u = B.create_promise () in
    let b_done, b_done_u = B.create_promise () in
    let defect = Failure "acquire defect" in
    let releases = ref [] in
    let acquire = function
      | `A ->
          E.sync (fun () ->
              B.resolve a_done_u ();
              "a")
      | `B ->
          B.await_effect a_done
          |> E.bind (fun () ->
                 E.sync (fun () ->
                     B.resolve b_done_u ();
                     "b"))
      | `Defect ->
          B.await_effect b_done
          |> E.bind (fun () -> E.sync (fun () -> raise defect))
    in
    let release resource =
      E.sync (fun () -> releases := resource :: !releases)
    in
    (match
       B.run rt
         (E.with_scope
            (E.acquire_all_par ~acquire ~release [ `A; `B; `Defect ]))
     with
    | Exit.Error (Cause.Die die) when die.exn == defect -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected acquire defect, got %a" (Cause.pp pp_hidden)
          cause
    | Exit.Ok _ -> Alcotest.fail "expected acquire defect");
    Alcotest.(check (list string))
      "defect reverse rollback exactly once" [ "b"; "a" ]
      (List.rev !releases)

  let test_acquire_all_par_cancellation_cleans_late_completion () =
    B.with_runtime @@ fun ctx rt ->
    let a_done, a_done_u = B.create_promise () in
    let late_started, late_started_u = B.create_promise () in
    let failure_started, failure_started_u = B.create_promise () in
    let allow_late, allow_late_u = B.create_promise () in
    let late_completed = ref false in
    let body_ran = ref false in
    let releases = ref [] in
    let releases_before_owner_exit = ref [] in
    let acquire = function
      | `A ->
          E.sync (fun () ->
              B.resolve a_done_u ();
              "a")
      | `Late ->
          E.sync (fun () -> B.resolve late_started_u ())
          |> E.bind (fun () ->
                 E.uninterruptible
                   (B.await_effect allow_late
                   |> E.bind (fun () ->
                          E.sync (fun () ->
                              late_completed := true;
                              "late"))))
      | `Fail ->
          B.await_effect a_done
          |> E.bind (fun () -> B.await_effect late_started)
          |> E.bind (fun () ->
                 E.sync (fun () -> B.resolve failure_started_u ()))
          |> E.bind (fun () -> E.fail `Acquire)
    in
    let release resource =
      E.sync (fun () -> releases := resource :: !releases)
    in
    let acquired =
      E.acquire_all_par ~acquire ~release [ `A; `Late; `Fail ]
      |> E.map (fun _ -> body_ran := true)
      |> E.bind_error (fun `Acquire ->
             E.sync (fun () ->
                 releases_before_owner_exit := List.rev !releases))
    in
    let fiber = B.fork_run ctx rt (E.with_scope acquired) in
    ignore (B.await failure_started : unit);
    B.yield ();
    B.resolve allow_late_u ();
    check_exit_ok Alcotest.unit "failure recovered" () (B.await fiber);
    Alcotest.(check bool) "late acquisition completed" true !late_completed;
    Alcotest.(check bool) "success continuation skipped" false !body_ran;
    Alcotest.(check (list string))
      "transaction cleaned before owner scope exit" [ "late"; "a" ]
      !releases_before_owner_exit;
    Alcotest.(check (list string))
      "owner scope registers no duplicate releases" [ "late"; "a" ]
      (List.rev !releases)

  let test_acquire_all_par_transfers_across_scope_exits () =
    B.with_runtime @@ fun _ctx rt ->
    let run exit_kind =
      let first_done, first_done_u = B.create_promise () in
      let releases = ref [] in
      let acquire = function
        | `First ->
            E.sync (fun () ->
                B.resolve first_done_u ();
                "first")
        | `Second ->
            B.await_effect first_done |> E.map (fun () -> "second")
      in
      let release resource =
        E.sync (fun () -> releases := resource :: !releases)
      in
      let body : (unit, [ `Body ]) E.t =
        E.sync (fun () ->
            Alcotest.(check (list string))
              "resources stay owned through body" [] !releases)
        |> E.bind (fun () ->
               match exit_kind with
               | `Success -> E.unit
               | `Typed -> E.fail `Body
               | `Defect -> E.sync (fun () -> failwith "body defect")
               | `Interrupt -> runtime_interrupt_effect ())
      in
      let eff =
        E.with_scope
          (E.acquire_all_par ~acquire ~release [ `First; `Second ]
          |> E.bind (fun resources ->
                 Alcotest.(check (list string))
                   "resources in input order" [ "first"; "second" ] resources;
                 body))
      in
      let exit = B.run rt eff in
      Alcotest.(check (list string))
        "scope release order" [ "second"; "first" ] (List.rev !releases);
      exit
    in
    check_exit_ok Alcotest.unit "success" () (run `Success);
    (match run `Typed with
    | Exit.Error (Cause.Fail `Body) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected typed failure, got %a" (Cause.pp pp_hidden)
          cause
    | Exit.Ok () -> Alcotest.fail "expected typed failure");
    (match run `Defect with
    | Exit.Error (Cause.Die _) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected defect, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok () -> Alcotest.fail "expected defect");
    match run `Interrupt with
    | Exit.Error cause when Cause.is_interrupt_only cause -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected interruption, got %a" (Cause.pp pp_hidden)
          cause
    | Exit.Ok () -> Alcotest.fail "expected interruption"

  let test_acquire_all_par_release_failures_preserve_diagnostics () =
    B.with_runtime @@ fun _ctx rt ->
    let run fail_body =
      let first_done, first_done_u = B.create_promise () in
      let releases = ref [] in
      let acquire = function
        | 1 ->
            E.sync (fun () ->
                B.resolve first_done_u ();
                1)
        | value -> B.await_effect first_done |> E.map (fun () -> value)
      in
      let release resource =
        E.sync (fun () -> releases := resource :: !releases)
        |> E.bind (fun () -> E.fail (`Release resource))
      in
      let body = if fail_body then E.fail `Body else E.unit in
      let exit =
        B.run rt
          (E.with_scope
             (E.acquire_all_par ~acquire ~release [ 1; 2 ]
             |> E.bind (fun _ -> body)))
      in
      Alcotest.(check (list int))
        "all releases attempted in reverse order" [ 2; 1 ]
        (List.rev !releases);
      exit
    in
    let expected_finalizers =
      Cause.Finalizer.Sequential
        [ Cause.Finalizer.Fail { error = "<typed failure>"; rendered = "<typed failure>" };
          Cause.Finalizer.Fail { error = "<typed failure>"; rendered = "<typed failure>" } ]
    in
    (match run false with
    | Exit.Error (Cause.Finalizer finalizers)
      when Cause.Finalizer.equal finalizers expected_finalizers ->
        ()
    | Exit.Error cause ->
        Alcotest.failf "expected complete finalizer diagnostics, got %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok () -> Alcotest.fail "expected finalizer failure");
    match run true with
    | Exit.Error (Cause.Suppressed { primary = Cause.Fail `Body; finalizer })
      when Cause.Finalizer.equal finalizer expected_finalizers ->
        ()
    | Exit.Error cause ->
        Alcotest.failf "expected primary with suppressed finalizers, got %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok () -> Alcotest.fail "expected body and finalizer failure"

  let test_acquire_all_par_results_preserve_input_order () =
    B.with_runtime @@ fun ctx rt ->
    let gates = Array.init 4 (fun _ -> B.create_promise ()) in
    let started = Atomic.make 0 in
    let completions = ref [] in
    let releases = ref [] in
    let acquire value =
      E.sync (fun () -> ignore (Atomic.fetch_and_add started 1))
      |> E.bind (fun () -> B.await_effect (fst gates.(value)))
      |> E.bind (fun () ->
             E.sync (fun () ->
                 completions := value :: !completions;
                 value))
    in
    let release value = E.sync (fun () -> releases := value :: !releases) in
    let fiber =
      B.fork_run ctx rt
        (E.with_scope
           (E.acquire_all_par ~acquire ~release [ 0; 1; 2; 3 ]))
    in
    wait_until (fun () -> Atomic.get started = 4);
    List.iteri
      (fun completed index ->
        B.resolve (snd gates.(index)) ();
        wait_until (fun () -> List.length !completions = completed + 1))
      [ 3; 1; 2; 0 ];
    check_exit_ok Alcotest.(list int) "input order" [ 0; 1; 2; 3 ]
      (B.await fiber);
    Alcotest.(check (list int))
      "forced completion order" [ 3; 1; 2; 0 ] (List.rev !completions);
    Alcotest.(check (list int))
      "reverse completion release order" [ 0; 2; 1; 3 ]
      (List.rev !releases)

  let test_acquire_release_finalizers_run_lifo_sequentially () =
    B.with_runtime @@ fun _ctx rt ->
    let a_started = Atomic.make false in
    let b_started = Atomic.make false in
    let trail = ref [] in
    let resource release =
      E.acquire_release ~acquire:E.unit ~release:(fun () -> E.sync release)
    in
    let a =
      resource (fun () ->
          Atomic.set a_started true;
          trail := "a" :: !trail)
    in
    let b =
      resource (fun () ->
          Atomic.set b_started true;
          trail := "b" :: !trail)
    in
    let c =
      E.acquire_release ~acquire:E.unit ~release:(fun () ->
          B.yield_effect ()
          |> E.bind (fun () ->
                 E.sync (fun () ->
                     Alcotest.(check bool)
                       "a not started before c finishes" false
                       (Atomic.get a_started);
                     Alcotest.(check bool)
                       "b not started before c finishes" false
                       (Atomic.get b_started);
                     trail := "c" :: !trail)))
    in
    let eff = E.with_scope (E.concat [ a; b; c ] |> E.map (fun _ -> ())) in
    run_ok rt eff;
    Alcotest.(check (list string)) "lifo order" [ "c"; "b"; "a" ]
      (List.rev !trail)

  let test_acquire_release_finalizer_failure_keeps_running_lifo () =
    B.with_runtime @@ fun _ctx rt ->
    let trail = ref [] in
    let resource release =
      E.acquire_release ~acquire:E.unit ~release:(fun () -> E.sync release)
    in
    let eff =
      E.with_scope
        (E.concat
           [
             resource (fun () -> trail := "a" :: !trail);
             resource (fun () ->
                 trail := "b" :: !trail;
                 failwith "b release");
             resource (fun () ->
                 trail := "c" :: !trail;
                 failwith "c release");
           ])
    in
    (match B.run rt eff with
    | Exit.Error
        (Cause.Finalizer
          (Cause.Finalizer.Sequential
            [ Cause.Finalizer.Die _; Cause.Finalizer.Die _ ])) ->
        ()
    | Exit.Error cause ->
        Alcotest.failf "expected sequential finalizer failures, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok () -> Alcotest.fail "expected finalizer failures");
    Alcotest.(check (list string)) "all finalizers ran" [ "c"; "b"; "a" ]
      (List.rev !trail)

  let test_repeat_releases_resources_each_iteration () =
    B.with_runtime @@ fun _ctx rt ->
    let active = ref 0 in
    let max_active = ref 0 in
    let acquire =
      E.sync (fun () ->
          incr active;
          max_active := max !max_active !active)
    in
    let release () = E.sync (fun () -> decr active) in
    let eff =
      E.repeat ~schedule:(Schedule.recurs 2)
        (E.acquire_release ~acquire ~release)
    in
    ignore (run_ok rt eff : int);
    Alcotest.(check int) "released at end" 0 !active;
    Alcotest.(check int) "one live resource per iteration" 1 !max_active

  let test_effect_timeout_uses_virtual_clock () =
    B.with_test_clock @@ fun ctx clock rt ->
    let eff =
      E.pure "done"
      |> E.delay (Duration.seconds 10)
      |> E.timeout (Duration.seconds 5)
      |> E.bind_error (fun (`Timeout : [ `Timeout ]) -> E.pure "timeout")
    in
    let promise = B.fork_run ctx rt eff in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.seconds 5);
    check_exit_ok Alcotest.string "timed out" "timeout" (B.await promise)

  let test_effect_timeout_allows_fast_success () =
    B.with_test_clock @@ fun ctx clock rt ->
    let eff =
      E.pure "done"
      |> E.delay (Duration.seconds 2)
      |> E.timeout (Duration.seconds 5)
      |> E.bind_error (fun (`Timeout : [ `Timeout ]) -> E.pure "timeout")
    in
    let promise = B.fork_run ctx rt eff in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.seconds 2);
    check_exit_ok Alcotest.string "completed" "done" (B.await promise)

  let test_effect_timeout_preserves_user_timeout_failure () =
    B.with_test_clock @@ fun ctx clock rt ->
    let eff =
      E.par
        (E.fail `Timeout |> E.delay (Duration.seconds 1))
        (E.delay (Duration.seconds 10) E.unit)
      |> E.timeout (Duration.seconds 5)
    in
    let promise = B.fork_run ctx rt eff in
    wait_for_sleepers clock 3;
    B.adjust_clock clock (Duration.seconds 1);
    match B.await promise with
    | Exit.Error (Cause.Fail `Timeout) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected preserved user Timeout, got %a"
          (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
          cause
    | Exit.Ok _ -> Alcotest.fail "expected user Timeout failure"

  let test_effect_timeout_nested_cancel_maps_to_outer_timeout () =
    B.with_test_clock @@ fun ctx clock rt ->
    let inner =
      E.pure "done"
      |> E.delay (Duration.seconds 10)
      |> E.timeout (Duration.seconds 10)
    in
    let eff =
      inner
      |> E.timeout (Duration.seconds 5)
      |> E.bind_error (fun (`Timeout : [ `Timeout ]) -> E.fail `Total_timeout)
    in
    let promise = B.fork_run ctx rt eff in
    wait_for_sleepers clock 3;
    B.adjust_clock clock (Duration.seconds 5);
    match B.await promise with
    | Exit.Error (Cause.Fail `Total_timeout) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected mapped timeout, got %a"
          (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
          cause
    | Exit.Ok _ -> Alcotest.fail "expected mapped timeout"

  type typed_timeout_err = [ `Slow | `Inner | `Outer ]

  let test_effect_timeout_as_keeps_exact_error_row () =
    B.with_runtime @@ fun _ctx rt ->
    let eff : (string, [ `Slow ]) E.t =
      E.pure "ok" |> E.timeout_as (Duration.seconds 1) ~on_timeout:`Slow
    in
    Alcotest.(check string) "ok" "ok" (run_ok rt eff)

  let test_effect_timeout_as_maps_delayed_effect () =
    B.with_test_clock @@ fun ctx clock rt ->
    let eff : (string, typed_timeout_err) E.t =
      E.pure "done"
      |> E.delay (Duration.seconds 10)
      |> E.timeout_as (Duration.seconds 5) ~on_timeout:`Slow
    in
    let promise = B.fork_run ctx rt eff in
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.seconds 5);
    match B.await promise with
    | Exit.Error (Cause.Fail `Slow) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected typed timeout, got %a"
          (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
          cause
    | Exit.Ok _ -> Alcotest.fail "expected typed timeout"

  let test_effect_timeout_as_nested_cancel_maps_to_outer_timeout () =
    B.with_test_clock @@ fun ctx clock rt ->
    let inner : (string, typed_timeout_err) E.t =
      E.pure "done"
      |> E.delay (Duration.seconds 10)
      |> E.timeout_as (Duration.seconds 10) ~on_timeout:`Inner
    in
    let eff = inner |> E.timeout_as (Duration.seconds 5) ~on_timeout:`Outer in
    let promise = B.fork_run ctx rt eff in
    wait_for_sleepers clock 3;
    B.adjust_clock clock (Duration.seconds 5);
    match B.await promise with
    | Exit.Error (Cause.Fail `Outer) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected outer typed timeout, got %a"
          (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
          cause
    | Exit.Ok _ -> Alcotest.fail "expected outer typed timeout"

  let test_effect_timeout_as_preserves_simultaneous_body_failure () =
    B.with_test_clock @@ fun ctx clock rt ->
    let eff : (unit, [ `Slow | `Body ]) E.t =
      E.fail `Body
      |> E.delay (Duration.seconds 5)
      |> E.uninterruptible
      |> E.timeout_as (Duration.seconds 5) ~on_timeout:`Slow
    in
    let promise = B.fork_run ctx rt eff in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.seconds 5);
    match B.await promise with
    | Exit.Error cause ->
        if not (typed_timeout_cause_contains_body_failure cause) then
          Alcotest.failf "expected body failure in cause, got %a"
            (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
            cause
    | Exit.Ok _ -> Alcotest.fail "expected simultaneous timeout/body failure"

  let test_effect_timeout_as_preserves_cancelled_body_finalizer_failure () =
    B.with_test_clock @@ fun ctx clock rt ->
    let released = ref false in
    let eff : (unit, [ `Slow | `Release ]) E.t =
      E.with_scope
        (E.acquire_release ~acquire:E.unit
           ~release:(fun () ->
             released := true;
             E.fail `Release)
        |> E.bind (fun () -> E.delay (Duration.seconds 10) E.unit))
      |> E.timeout_as (Duration.seconds 5) ~on_timeout:`Slow
    in
    let promise = B.fork_run ctx rt eff in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.seconds 5);
    match B.await promise with
    | Exit.Error cause ->
        Alcotest.(check bool)
          "timeout failure observed" true
          (timeout_finalizer_cause_contains_slow cause);
        Alcotest.(check bool)
          "cancelled body finalizer failure is preserved" true
          (cause_finalizer_contains "<typed failure>" cause);
        Alcotest.(check bool) "release ran before timeout returned" true !released
    | Exit.Ok _ -> Alcotest.fail "expected timeout/finalizer failure"

  let tests =
    [
      ( "Effect resource/timeout",
        [
          Alcotest.test_case "acquire release" `Quick test_acquire_release;
          Alcotest.test_case "acquire release root finalizer" `Quick
            test_acquire_release_root_scope_runs_finalizer;
          Alcotest.test_case "acquire release root failure finalizer" `Quick
            test_acquire_release_root_scope_runs_finalizer_on_failure;
          Alcotest.test_case "daemon drain waits pending finalizer" `Quick
            test_daemon_drain_waits_for_pending_finalizer;
          Alcotest.test_case "daemon failure logs diagnostic" `Quick
            test_daemon_failure_logs_diagnostic;
          Alcotest.test_case "daemon interrupt stays quiet" `Quick
            test_daemon_interrupt_does_not_log_diagnostic;
          Alcotest.test_case "acquire release on failure" `Quick
            test_acquire_release_on_failure;
          Alcotest.test_case "acquire release suppresses release failure" `Quick
            test_acquire_release_suppresses_release_failure;
          Alcotest.test_case "acquire release release failure after success"
            `Quick test_acquire_release_release_failure_after_success;
          Alcotest.test_case "acquire release releases on defect" `Quick
            test_acquire_release_releases_on_defect;
          Alcotest.test_case
            "acquire release suppresses release failure after defect" `Quick
            test_acquire_release_suppresses_release_failure_after_defect;
          Alcotest.test_case "acquire_use_release success" `Quick
            test_acquire_use_release_success;
          Alcotest.test_case "acquire_use_release lexical bracket" `Quick
            test_acquire_use_release_is_lexical_bracket;
          Alcotest.test_case "acquire_use_release typed failure releases"
            `Quick test_acquire_use_release_typed_failure_releases;
          Alcotest.test_case "acquire_use_release defect releases" `Quick
            test_acquire_use_release_defect_releases;
          Alcotest.test_case
            "acquire_use_release suppresses release failure after defect" `Quick
            test_acquire_use_release_suppresses_release_failure_after_defect;
          Alcotest.test_case "acquire_use_release releases on cancel" `Quick
            test_acquire_use_release_releases_on_cancel;
          Alcotest.test_case
            "acquire_use_release release failure after success" `Quick
            test_acquire_use_release_release_failure_after_success;
          Alcotest.test_case "with_resource let@ success" `Quick
            test_with_resource_let_at_success;
          Alcotest.test_case "acquire_all_par admission and concurrency" `Quick
            test_acquire_all_par_admission_and_concurrency;
          Alcotest.test_case "acquire_all_par failure reverse cleanup" `Quick
            test_acquire_all_par_failure_releases_reverse_success_order;
          Alcotest.test_case "acquire_all_par parent interruption rollback"
            `Quick test_acquire_all_par_parent_interruption_rolls_back_once;
          Alcotest.test_case "acquire_all_par rollback release diagnostics"
            `Quick test_acquire_all_par_rollback_release_failure_diagnostics;
          Alcotest.test_case "acquire_all_par acquire defect rollback" `Quick
            test_acquire_all_par_acquire_defect_rolls_back;
          Alcotest.test_case "acquire_all_par cancellation late completion"
            `Quick test_acquire_all_par_cancellation_cleans_late_completion;
          Alcotest.test_case "acquire_all_par scope exit ownership" `Quick
            test_acquire_all_par_transfers_across_scope_exits;
          Alcotest.test_case "acquire_all_par release diagnostics" `Quick
            test_acquire_all_par_release_failures_preserve_diagnostics;
          Alcotest.test_case "acquire_all_par input order" `Quick
            test_acquire_all_par_results_preserve_input_order;
          Alcotest.test_case "acquire release finalizers lifo sequential"
            `Quick test_acquire_release_finalizers_run_lifo_sequentially;
          Alcotest.test_case "acquire release finalizer failure keeps running"
            `Quick test_acquire_release_finalizer_failure_keeps_running_lifo;
          Alcotest.test_case "repeat releases resources each iteration" `Quick
            test_repeat_releases_resources_each_iteration;
          Alcotest.test_case "timeout uses virtual clock" `Quick
            test_effect_timeout_uses_virtual_clock;
          Alcotest.test_case "timeout allows fast success" `Quick
            test_effect_timeout_allows_fast_success;
          Alcotest.test_case "timeout preserves user timeout failure" `Quick
            test_effect_timeout_preserves_user_timeout_failure;
          Alcotest.test_case "nested timeout maps outer timeout" `Quick
            test_effect_timeout_nested_cancel_maps_to_outer_timeout;
          Alcotest.test_case "timeout_as exact error row" `Quick
            test_effect_timeout_as_keeps_exact_error_row;
          Alcotest.test_case "timeout_as maps delayed eff" `Quick
            test_effect_timeout_as_maps_delayed_effect;
          Alcotest.test_case "timeout_as nested maps outer timeout" `Quick
            test_effect_timeout_as_nested_cancel_maps_to_outer_timeout;
          Alcotest.test_case "timeout_as preserves simultaneous failure" `Quick
            test_effect_timeout_as_preserves_simultaneous_body_failure;
          Alcotest.test_case "timeout_as preserves cancelled finalizer" `Quick
            test_effect_timeout_as_preserves_cancelled_body_finalizer_failure;
        ] );
    ]
end
