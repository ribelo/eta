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
    | Cause.Finalizer.Fail actual -> String.equal expected actual
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

  let test_daemon_drains_acquire_release_finalizer () =
    B.with_runtime @@ fun _ctx rt ->
    let released = Atomic.make false in
    let daemon_body =
      E.acquire_release ~acquire:E.unit
        ~release:(fun () -> E.sync (fun () -> Atomic.set released true))
    in
    run_ok rt (E.daemon daemon_body);
    B.drain rt;
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
            finalizer = Cause.Finalizer.Fail "<typed failure>";
          }) ->
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
      (Cause.Finalizer (Cause.Finalizer.Fail "<typed failure>"))
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
          { primary = Cause.Die _; finalizer = Cause.Finalizer.Fail "<typed failure>" })
      ->
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
          { primary = Cause.Die _; finalizer = Cause.Finalizer.Fail "<typed failure>" })
      ->
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
      (Cause.Finalizer (Cause.Finalizer.Fail "<typed failure>"))
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

  let acquire_into owner ~acquire ~release =
    E.Expert.make ~inherit_:acquire ~capabilities:[ `Resources ] @@ fun child ->
    match E.Expert.eval child acquire with
    | Exit.Error _ as error -> error
    | Exit.Ok resource ->
        E.Expert.eval owner
          (E.acquire_release ~acquire:(E.pure resource) ~release)

  let parallel_acquire_recipe acquisitions ~release body =
    E.with_scope
      (E.Expert.make ~capabilities:[ `Concurrency; `Resources ] @@ fun owner ->
       E.Expert.eval owner
         (E.map_par
            (fun acquire -> acquire_into owner ~acquire ~release)
            acquisitions
          |> E.bind body))

  let test_parallel_acquire_recipe_partial_failure () =
    B.with_runtime @@ fun _ctx rt ->
    let acquired1, acquired1_u = B.create_promise () in
    let trail = ref [] in
    let releases = ref 0 in
    let body_ran = ref false in
    let acquire1 =
      E.sync (fun () ->
          trail := "acquire1" :: !trail;
          B.resolve acquired1_u ();
          "one")
    in
    let acquire2 =
      B.await_effect acquired1
      |> E.bind (fun () ->
             E.sync (fun () -> trail := "acquire2-fail" :: !trail))
      |> E.bind (fun () -> E.fail `Acquire2)
    in
    let release resource =
      E.sync (fun () ->
          incr releases;
          trail := ("release:" ^ resource) :: !trail)
    in
    let eff =
      parallel_acquire_recipe [ acquire1; acquire2 ] ~release (fun _ ->
          E.sync (fun () -> body_ran := true))
    in
    (match B.run rt eff with
    | Exit.Error (Cause.Fail `Acquire2) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected second acquire failure, got %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok () -> Alcotest.fail "expected second acquire failure");
    Alcotest.(check bool) "body skipped" false !body_ran;
    Alcotest.(check int) "registered resource released once" 1 !releases;
    Alcotest.(check (list string))
      "release follows failed acquire"
      [ "acquire1"; "acquire2-fail"; "release:one" ]
      (List.rev !trail)

  let test_parallel_acquire_recipe_reverse_release_order () =
    B.with_runtime @@ fun _ctx rt ->
    let run fail_body =
      let acquired1, acquired1_u = B.create_promise () in
      let trail = ref [] in
      let acquire1 =
        E.sync (fun () ->
            trail := "acquire1" :: !trail;
            B.resolve acquired1_u ();
            "one")
      in
      let acquire2 =
        B.await_effect acquired1
        |> E.bind (fun () ->
               E.sync (fun () ->
                   trail := "acquire2" :: !trail;
                   "two"))
      in
      let release resource =
        E.sync (fun () -> trail := ("release:" ^ resource) :: !trail)
      in
      let body _resources =
        E.sync (fun () -> trail := "body" :: !trail)
        |> E.bind (fun () -> if fail_body then E.fail `Body else E.unit)
      in
      let exit =
        B.run rt
          (parallel_acquire_recipe [ acquire1; acquire2 ] ~release body)
      in
      (exit, List.rev !trail)
    in
    let expected =
      [ "acquire1"; "acquire2"; "body"; "release:two"; "release:one" ]
    in
    let success_exit, success_trail = run false in
    check_exit_ok Alcotest.unit "success" () success_exit;
    Alcotest.(check (list string)) "success order" expected success_trail;
    let failure_exit, failure_trail = run true in
    (match failure_exit with
    | Exit.Error (Cause.Fail `Body) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected typed body failure, got %a" (Cause.pp pp_hidden)
          cause
    | Exit.Ok () -> Alcotest.fail "expected typed body failure");
    Alcotest.(check (list string)) "typed failure order" expected failure_trail

  let test_parallel_acquire_recipe_nested_ladder_parity () =
    B.with_runtime @@ fun _ctx rt ->
    let run build =
      let acquired1, acquired1_u = B.create_promise () in
      let trail = ref [] in
      let acquire1 =
        E.sync (fun () ->
            trail := "acquire1" :: !trail;
            B.resolve acquired1_u ();
            "one")
      in
      let acquire2 =
        B.await_effect acquired1
        |> E.bind (fun () ->
               E.sync (fun () ->
                   trail := "acquire2" :: !trail;
                   "two"))
      in
      let release resource =
        E.sync (fun () -> trail := ("release:" ^ resource) :: !trail)
      in
      let body () =
        E.sync (fun () -> trail := "body" :: !trail)
        |> E.bind (fun () -> E.fail `Body)
      in
      let exit = B.run rt (build acquire1 acquire2 release body) in
      (exit, List.rev !trail)
    in
    let recipe =
      run (fun acquire1 acquire2 release body ->
          parallel_acquire_recipe [ acquire1; acquire2 ] ~release (fun _ ->
              body ()))
    in
    let ladder =
      run (fun acquire1 acquire2 release body ->
          E.with_resource ~acquire:acquire1 ~release @@ fun _ ->
          E.with_resource ~acquire:acquire2 ~release @@ fun _ -> body ())
    in
    let recipe_exit, recipe_trail = recipe in
    let ladder_exit, ladder_trail = ladder in
    Alcotest.(check bool)
      "same exit" true
      (Exit.equal ( = ) ( = ) recipe_exit ladder_exit);
    Alcotest.(check (list string))
      "same release order" ladder_trail recipe_trail

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
          Alcotest.test_case "daemon drains acquire release finalizer" `Quick
            test_daemon_drains_acquire_release_finalizer;
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
          Alcotest.test_case "parallel acquire recipe partial failure" `Quick
            test_parallel_acquire_recipe_partial_failure;
          Alcotest.test_case "parallel acquire recipe release order" `Quick
            test_parallel_acquire_recipe_reverse_release_order;
          Alcotest.test_case "parallel acquire recipe ladder parity" `Quick
            test_parallel_acquire_recipe_nested_ladder_parity;
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
