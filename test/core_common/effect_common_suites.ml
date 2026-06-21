module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  open Eta

  let pp_hidden ppf _ = Format.pp_print_string ppf "<effect>"

  let runtime_interrupt_effect () =
    Effect.Expert.make ~leaf_name:"test.interrupt" @@ fun context ->
    let contract = Effect.Expert.contract context in
    contract.Eta.Runtime_contract.cancel_sub @@ fun cancel_context ->
    contract.Eta.Runtime_contract.cancel cancel_context Exit;
    contract.Eta.Runtime_contract.await_cancel ()

  let run_ok rt eff =
    match B.run rt eff with
    | Exit.Ok value -> value
    | Exit.Error cause ->
        Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause

  let effect_error_cause cause =
    Effect.Expert.make ~leaf_name:"test.error-cause" @@ fun _context ->
    Exit.Error cause

  let expect_typed_failure_eq testable exit expected =
    match exit with
    | Exit.Error (Cause.Fail actual) ->
        Alcotest.check testable "typed failure" expected actual
    | Exit.Error cause ->
        Alcotest.failf "expected typed failure, got %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected typed failure"

  let string_cause =
    Alcotest.testable (Cause.pp Format.pp_print_string) (Cause.equal String.equal)

  let check_exit_error testable label expected = function
    | Exit.Error actual -> Alcotest.check testable label expected actual
    | Exit.Ok _ -> Alcotest.failf "%s: expected Error" label

  let check_exit_ok testable label expected = function
    | Exit.Ok actual -> Alcotest.check testable label expected actual
    | Exit.Error cause ->
        Alcotest.failf "%s: expected Ok, got %a" label (Cause.pp pp_hidden) cause

  let expect_interrupted label = function
    | `Cancelled -> ()
    | `Returned (Exit.Error (Cause.Interrupt _)) -> ()
    | `Returned (Exit.Ok _) ->
        Alcotest.failf "%s: expected interruption, got Ok" label
    | `Returned (Exit.Error cause) ->
        Alcotest.failf "%s: expected interruption, got %a" label
          (Cause.pp pp_hidden) cause

  let wait_for_sleepers clock expected =
    let rec loop attempts =
      if B.sleeper_count clock >= expected then ()
      else if attempts = 0 then
        Alcotest.failf "expected at least %d sleepers, got %d" expected
          (B.sleeper_count clock)
      else (
        B.yield ();
        loop (attempts - 1))
    in
    loop 20

  let rec string_cause_contains expected = function
    | Cause.Fail actual -> String.equal expected actual
    | Cause.Die _ | Cause.Interrupt _ -> false
    | Cause.Sequential causes | Cause.Concurrent causes ->
        List.exists (string_cause_contains expected) causes
    | Cause.Finalizer _ -> false
    | Cause.Suppressed { primary; finalizer = _ } ->
        string_cause_contains expected primary

  let check_concurrent_cause label = function
    | Cause.Concurrent (_ :: _ :: _) -> ()
    | cause ->
        Alcotest.failf "%s: expected concurrent cause, got %a" label
          (Cause.pp Format.pp_print_string) cause

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

  let check_suppressed_finalizer label expected cause =
    Alcotest.(check bool) label true (cause_finalizer_contains expected cause)

  type dependency_deps = {
    add : int -> int;
    mul : int -> int;
  }

  let test_pure () =
    B.with_runtime @@ fun _ctx rt ->
    Alcotest.(check int) "pure" 42 (run_ok rt (Effect.pure 42))

  let test_map () =
    B.with_runtime @@ fun _ctx rt ->
    let e = Effect.pure 1 |> Effect.map (fun n -> n + 1) in
    Alcotest.(check int) "map" 2 (run_ok rt e)

  let test_collect_names () =
    let e =
      Effect.concat
        [
          Effect.named "leaf-a" (Effect.sync (fun () -> ()))
          |> Effect.map (fun _ -> ());
          Effect.sync (fun () -> ());
          Effect.named "leaf-b" (Effect.sync (fun () -> ()));
        ]
      |> Effect.named "outer"
    in
    Alcotest.(check (list string))
      "names in pre-order"
      [ "outer"; "leaf-a"; "leaf-b" ]
      (Effect.collect_names e)

  let test_effect_map_bind_tap_runtime () =
    B.with_runtime @@ fun _ctx rt ->
    let observed = ref [] in
    let eff =
      Effect.pure 1
      |> Effect.map (fun n -> n + 1)
      |> Effect.bind (fun n -> Effect.pure (n * 2))
      |> Effect.tap (fun n ->
             Effect.named "tap" (Effect.sync (fun () -> observed := n :: !observed)))
      |> Effect.map (fun n -> n + 1)
    in
    Alcotest.(check int) "value" 5 (run_ok rt eff);
    Alcotest.(check (list int)) "tap saw pre-map value" [ 4 ] !observed

  let test_effect_tap_observer_runtime () =
    B.with_runtime @@ fun _ctx rt ->
    let observed = ref [] in
    let eff =
      Effect.pure 10
      |> Effect.tap (fun n ->
             Effect.sync (fun () ->
                 observed := n :: !observed;
                 "ignored"))
      |> Effect.map (( + ) 1)
    in
    Alcotest.(check int) "value" 11 (run_ok rt eff);
    Alcotest.(check (list int)) "observed" [ 10 ] !observed;
    let defect =
      Effect.pure 1
      |> Effect.tap (fun _ -> Effect.sync (fun () -> failwith "tap crash"))
    in
    match B.run rt defect with
    | Exit.Error (Cause.Die { exn; _ }) ->
        Alcotest.(check string)
          "observer defect" "Failure(\"tap crash\")"
          (Printexc.to_string exn)
    | Exit.Error cause ->
        Alcotest.failf "expected Die, got %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected tap defect"

  let test_effect_catch_success_and_failure () =
    B.with_runtime @@ fun _ctx rt ->
    let success =
      Effect.pure 1
      |> Effect.catch (fun (`Unexpected : [ `Unexpected ]) ->
             Effect.fail `Handler_ran)
    in
    let failure =
      Effect.fail `First
      |> Effect.catch (fun (`First : [ `First ]) -> Effect.fail `Second)
      |> Effect.catch (fun (`Second : [ `Second ]) -> Effect.pure "recovered")
    in
    Alcotest.(check int) "success bypasses catch" 1 (run_ok rt success);
    Alcotest.(check string) "failure recovers" "recovered" (run_ok rt failure)

  let test_effect_recover () =
    B.with_runtime @@ fun _ctx rt ->
    let recovered = Effect.fail `Bad |> Effect.recover (function `Bad -> 42) in
    Alcotest.(check int) "typed failure recovered" 42 (run_ok rt recovered);
    (match
       B.run rt
         (Effect.sync (fun () -> failwith "boom")
         |> Effect.recover (fun _ -> 0))
     with
    | Exit.Error (Cause.Die _) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected defect, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected defect");
    match
      B.run rt
        (Effect.fail `Bad
        |> Effect.recover (function `Bad -> failwith "recover handler crash"))
    with
    | Exit.Error (Cause.Die _) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected handler defect, got %a" (Cause.pp pp_hidden)
          cause
    | Exit.Ok _ -> Alcotest.fail "expected handler defect"

  let test_effect_ignore_errors () =
    B.with_runtime @@ fun _ctx rt ->
    Alcotest.(check unit)
      "success preserved as unit" () (run_ok rt (Effect.unit |> Effect.ignore_errors));
    Alcotest.(check unit)
      "typed failure suppressed" ()
      (run_ok rt (Effect.fail `Bad |> Effect.ignore_errors));
    match
      B.run rt (Effect.sync (fun () -> failwith "boom") |> Effect.ignore_errors)
    with
    | Exit.Error (Cause.Die _) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected defect, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected defect"

  let test_effect_ignore () =
    B.with_runtime @@ fun _ctx rt ->
    let typed_cause cause =
      Effect.Expert.make ~leaf_name:"test.typed-cause" @@ fun _context ->
      Exit.Error cause
    in
    Alcotest.(check unit)
      "success value discarded" ()
      (run_ok rt (Effect.pure 7 |> Effect.ignore));
    Alcotest.(check unit)
      "typed failure suppressed" ()
      (run_ok rt (Effect.fail "bad" |> Effect.ignore));
    Alcotest.(check unit)
      "sequential typed failures suppressed" ()
      (run_ok rt
         (typed_cause
            (Cause.sequential [ Cause.Fail "left"; Cause.Fail "right" ])
         |> Effect.ignore));
    Alcotest.(check unit)
      "concurrent typed failures suppressed" ()
      (run_ok rt
         (typed_cause
            (Cause.concurrent [ Cause.Fail "left"; Cause.Fail "right" ])
         |> Effect.ignore));
    (match B.run rt (Effect.sync (fun () -> failwith "boom") |> Effect.ignore) with
    | Exit.Error (Cause.Die _) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected defect, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "ignore swallowed defect");
    (match
       B.run rt
         (Effect.named "interrupt" (runtime_interrupt_effect ()) |> Effect.ignore)
     with
    | Exit.Error (Cause.Interrupt None) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected interrupt, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "ignore swallowed interrupt");
    match
      B.run rt
        (Effect.finally (Effect.fail "cleanup") Effect.unit |> Effect.ignore)
    with
    | Exit.Error (Cause.Finalizer (Cause.Finalizer.Fail "<typed failure>")) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected finalizer diagnostic, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "ignore swallowed finalizer diagnostic"

  let test_effect_result () =
    B.with_runtime @@ fun _ctx rt ->
    Alcotest.(check (result int string))
      "success" (Ok 7) (run_ok rt (Effect.pure 7 |> Effect.result));
    Alcotest.(check (result int string))
      "typed failure"
      (Error "bad")
      (run_ok rt (Effect.fail "bad" |> Effect.result));
    (match
       B.run rt (Effect.sync (fun () -> failwith "boom") |> Effect.result)
     with
    | Exit.Error (Cause.Die _) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected defect, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected defect");
    match
      B.run rt
        (Effect.finally (Effect.fail "cleanup") Effect.unit |> Effect.result)
    with
    | Exit.Error (Cause.Finalizer (Cause.Finalizer.Fail _)) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected finalizer failure, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "expected finalizer failure"

  let test_effect_option () =
    B.with_runtime @@ fun _ctx rt ->
    Alcotest.(check (option int))
      "success" (Some 7) (run_ok rt (Effect.pure 7 |> Effect.option));
    Alcotest.(check (option int))
      "typed failure" None (run_ok rt (Effect.fail "bad" |> Effect.option));
    (match
       B.run rt (Effect.sync (fun () -> failwith "boom") |> Effect.option)
     with
    | Exit.Error (Cause.Die _) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected defect, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "option captured defect");
    match
      B.run rt
        (Effect.named "interrupt" (runtime_interrupt_effect ()) |> Effect.option)
    with
    | Exit.Error (Cause.Interrupt None) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected interrupt, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "option captured interrupt"

  let test_effect_exit () =
    B.with_runtime @@ fun _ctx rt ->
    let defect = Failure "body defect" in
    Alcotest.(check (testable (Exit.pp pp_hidden Format.pp_print_string) (Exit.equal ( = ) String.equal)))
      "success" (Exit.Ok 7) (run_ok rt (Effect.pure 7 |> Effect.exit));
    (match run_ok rt (Effect.fail "bad" |> Effect.exit) with
    | Exit.Error (Cause.Fail "bad") -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected typed failure exit, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "expected typed failure exit");
    (match
       run_ok rt
         (Effect.sync (fun () -> raise defect)
         |> Effect.exit)
     with
    | Exit.Error (Cause.Die { exn; _ }) when exn == defect -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected defect exit, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "expected defect exit");
    (match run_ok rt (runtime_interrupt_effect () |> Effect.exit) with
    | Exit.Error (Cause.Interrupt None) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected interrupt exit, got %a" (Cause.pp pp_hidden)
          cause
    | Exit.Ok _ -> Alcotest.fail "expected interrupt exit");
    match
      run_ok rt
        (Effect.finally (Effect.fail "cleanup") Effect.unit |> Effect.exit)
    with
    | Exit.Error (Cause.Finalizer (Cause.Finalizer.Fail "<typed failure>")) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected finalizer exit, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "expected finalizer exit"

  let test_effect_sleep_now_and_timed_use_runtime_clock () =
    B.with_test_clock @@ fun ctx clock rt ->
    B.set_clock clock 100;
    let program =
      Effect.now
      |> Effect.bind (fun before ->
             Effect.sleep (Duration.ms 25)
             |> Effect.bind (fun () ->
                    Effect.now
                    |> Effect.bind (fun after_sleep ->
                           Effect.timed
                             (Effect.sleep (Duration.ms 15)
                             |> Effect.map (fun () -> "done"))
                           |> Effect.bind (fun (elapsed, value) ->
                                  Effect.now
                                  |> Effect.map (fun after_timed ->
                                         ( before,
                                           after_sleep,
                                           elapsed,
                                           value,
                                           after_timed ))))))
    in
    let promise = B.fork_run ctx rt program in
    wait_for_sleepers clock 1;
    Alcotest.(check bool) "sleep waits" false (B.is_resolved promise);
    B.adjust_clock clock (Duration.ms 25);
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 15);
    match B.await promise with
    | Exit.Ok (before, after_sleep, elapsed, value, after_timed) ->
        Alcotest.(check int) "before" 100 before;
        Alcotest.(check int) "after sleep" 125 after_sleep;
        Alcotest.(check int) "elapsed" 15 (Duration.to_ms elapsed);
        Alcotest.(check string) "value" "done" value;
        Alcotest.(check int) "after timed" 140 after_timed
    | Exit.Error cause ->
        Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause

  let test_effect_timed_preserves_failures () =
    B.with_runtime @@ fun _ctx rt ->
    let defect = Failure "timed defect" in
    expect_typed_failure_eq Alcotest.string
      (B.run rt (Effect.fail "bad" |> Effect.timed))
      "bad";
    (match
       B.run rt
         (Effect.sync (fun () -> raise defect)
         |> Effect.timed)
     with
    | Exit.Error (Cause.Die { exn; _ }) when exn == defect -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected defect, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "timed captured defect");
    match
      B.run rt
        (Effect.named "interrupt" (runtime_interrupt_effect ()) |> Effect.timed)
    with
    | Exit.Error (Cause.Interrupt None) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected interrupt, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "timed captured interrupt"

  let test_effect_yield () =
    B.with_runtime @@ fun _ctx rt ->
    let eff = Effect.yield |> Effect.map (fun () -> 42) in
    Alcotest.(check int) "yield returns" 42 (run_ok rt eff)

  let test_effect_catch_handler_failure_uses_outer_key () =
    B.with_runtime @@ fun _ctx rt ->
    let eff =
      Effect.fail `Inner
      |> Effect.catch (fun (`Inner : [ `Inner ]) -> Effect.fail `Outer)
    in
    expect_typed_failure_eq
      (Alcotest.testable
         (fun fmt -> function
           | `Inner -> Format.pp_print_string fmt "inner"
           | `Outer -> Format.pp_print_string fmt "outer")
         ( = ))
      (B.run rt eff) `Outer

  let test_effect_from_result () =
    B.with_runtime @@ fun _ctx rt ->
    Alcotest.(check int) "ok" 7 (run_ok rt (Effect.from_result (Ok 7)));
    expect_typed_failure_eq Alcotest.string
      (B.run rt (Effect.from_result (Error "bad")))
      "bad"

  let test_effect_flatten_result () =
    B.with_runtime @@ fun _ctx rt ->
    let lift f = Effect.sync f |> Effect.flatten_result in
    Alcotest.(check int) "ok" 7 (run_ok rt (lift (fun () -> Ok 7)));
    expect_typed_failure_eq Alcotest.string
      (B.run rt (lift (fun () -> Error "bad")))
      "bad";
    match B.run rt (lift (fun () -> failwith "boom")) with
    | Exit.Error (Cause.Die _) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected defect, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected defect"

  let test_exit_to_result_only_converts_success_and_single_typed_failure () =
    Alcotest.(check (option (result int string)))
      "success" (Some (Ok 1)) (Exit.to_result (Exit.Ok 1));
    Alcotest.(check (option (result int string)))
      "typed failure"
      (Some (Error "bad"))
      (Exit.to_result (Exit.Error (Cause.Fail "bad")));
    Alcotest.(check (option (result int string)))
      "defect" None
      (Exit.to_result (Exit.Error (Cause.die (Failure "boom"))));
    Alcotest.(check (option (result int string)))
      "interrupt" None
      (Exit.to_result (Exit.Error Cause.interrupt));
    Alcotest.(check (option (result int string)))
      "sequential" None
      (Exit.to_result
         (Exit.Error (Cause.sequential [ Cause.Fail "left"; Cause.Fail "right" ])));
    Alcotest.(check (option (result int string)))
      "concurrent" None
      (Exit.to_result
         (Exit.Error (Cause.concurrent [ Cause.Fail "left"; Cause.Fail "right" ])));
    Alcotest.(check (option (result int string)))
      "suppressed" None
      (Exit.to_result
         (Exit.Error
            (Cause.suppressed ~primary:(Cause.Fail "body")
               ~finalizer:(Cause.Finalizer.Fail "release"))))

  let test_effect_map_error_maps_full_cause () =
    B.with_runtime @@ fun _ctx rt ->
    let eff =
      Effect.scoped
        (Effect.acquire_release ~acquire:Effect.unit
           ~release:(fun () -> Effect.fail `Release)
        |> Effect.bind (fun () -> Effect.fail `Body))
      |> Effect.map_error (function
           | `Body -> "body"
           | `Release -> "release")
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
        Alcotest.failf "expected mapped suppressed cause, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok () -> Alcotest.fail "expected mapped failure"

  let test_effect_map_error_preserves_defects_in_cause_tree () =
    B.with_runtime @@ fun _ctx rt ->
    let eff =
      Effect.scoped
        (Effect.acquire_release ~acquire:Effect.unit
           ~release:(fun () ->
             Effect.sync (fun () -> failwith "release defect"))
        |> Effect.bind (fun () -> Effect.fail `Body))
      |> Effect.map_error (function `Body -> "body")
    in
    match B.run rt eff with
    | Exit.Error
        (Cause.Suppressed
          { primary = Cause.Fail "body"; finalizer = Cause.Finalizer.Die _ }) ->
        ()
    | Exit.Error cause ->
        Alcotest.failf "expected mapped typed failure with preserved defect, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "expected suppressed defect"

  let test_effect_map_error_preserves_interrupts_in_cause_tree () =
    B.with_runtime @@ fun _ctx rt ->
    let eff =
      Effect.scoped
        (Effect.acquire_release ~acquire:Effect.unit
           ~release:(fun () -> runtime_interrupt_effect ())
        |> Effect.bind (fun () -> Effect.fail `Body))
      |> Effect.map_error (function `Body -> "body")
    in
    match B.run rt eff with
    | Exit.Error
        (Cause.Suppressed
          { primary = Cause.Fail "body"; finalizer = Cause.Finalizer.Interrupt _ }) ->
        ()
    | Exit.Error cause ->
        Alcotest.failf
          "expected mapped typed failure with preserved interrupt, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "expected suppressed interrupt"

  let test_effect_syntax_operators () =
    B.with_runtime @@ fun _ctx rt ->
    let open Eta.Syntax in
    let eff =
      let* a = Effect.pure 2 in
      let@ d = (fun k -> k 5) in
      let+ b = Effect.pure 3
      and+ c = Effect.pure 4 in
      a + b + c + d
    in
    Alcotest.(check int) "syntax result" 14 (run_ok rt eff)

  let test_effect_tap_error_observes_and_rethrows () =
    B.with_runtime @@ fun _ctx rt ->
    let observed = ref false in
    let eff =
      Effect.fail `Boom
      |> Effect.tap_error (fun (`Boom : [ `Boom ]) -> observed := true)
      |> Effect.catch (fun (`Boom : [ `Boom ]) -> Effect.pure "recovered")
    in
    Alcotest.(check string) "recovered" "recovered" (run_ok rt eff);
    Alcotest.(check bool) "observed" true !observed

  let test_effect_tap_error_observer_failure_preserves_typed_failure () =
    B.with_runtime @@ fun _ctx rt ->
    let eff =
      Effect.fail `My_error
      |> Effect.tap_error (fun (`My_error : [ `My_error ]) ->
             failwith "observer crash")
    in
    match B.run rt eff with
    | Exit.Error
        (Cause.Suppressed
          {
            primary = Cause.Fail `My_error;
            finalizer = Cause.Finalizer.Die { exn; _ };
          }) ->
        Alcotest.(check string)
          "observer defect" "Failure(\"observer crash\")"
          (Printexc.to_string exn)
    | Exit.Error cause ->
        Alcotest.failf "expected suppressed typed failure, got %a"
          (Cause.pp (fun fmt -> function
            | `My_error -> Format.pp_print_string fmt "My_error"))
          cause
    | Exit.Ok () -> Alcotest.fail "expected tap_error failure"

  let test_effect_tap_error_does_not_observe_defects () =
    B.with_runtime @@ fun _ctx rt ->
    let observed = ref false in
    let eff =
      Effect.sync (fun () -> failwith "body defect")
      |> Effect.tap_error (fun (_ : string) -> observed := true)
    in
    (match B.run rt eff with
    | Exit.Error (Cause.Die _) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected defect, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "expected defect");
    Alcotest.(check bool) "observer not called" false !observed

  let test_runtime_die_captures_diagnostics () =
    B.with_sampled_traced_runtime Sampler.always_off @@ fun _ctx rt _tracer ->
    let exn = Failure "diagnostic boom" in
    let eff =
      Effect.named "die.leaf" (Effect.sync (fun () -> raise exn))
      |> Effect.annotate ~key:"request.id" ~value:"r-1"
      |> Effect.fn __POS__ "diagnostic.fn"
    in
    match B.run rt eff with
    | Exit.Error (Cause.Die die) ->
        Alcotest.(check bool) "same exception" true (die.exn == exn);
        Alcotest.(check (option string)) "span name" (Some "die.leaf")
          die.span_name;
        Alcotest.(check (option string)) "annotation" (Some "r-1")
          (List.assoc_opt "request.id" die.annotations);
        Alcotest.(check bool) "loc annotation exists" true
          (Option.is_some (List.assoc_opt "loc" die.annotations));
        Alcotest.(check bool) "backtrace captured" true
          (Option.is_some die.backtrace)
    | _ -> Alcotest.fail "expected Die with diagnostics"

  let test_runtime_finalizer_die_captures_diagnostics () =
    B.with_runtime @@ fun _ctx rt ->
    let body_exn = Failure "body defect" in
    let release_exn = Failure "release defect" in
    let release () =
      Effect.named "release.leaf" (Effect.sync (fun () -> raise release_exn))
      |> Effect.annotate ~key:"phase" ~value:"release"
      |> Effect.named "release.span"
    in
    let body =
      Effect.named "body.leaf" (Effect.sync (fun () -> raise body_exn))
      |> Effect.named "body.span"
    in
    let eff =
      Effect.scoped
        (Effect.acquire_release ~acquire:(Effect.pure ()) ~release
        |> Effect.bind (fun () -> body))
    in
    match B.run rt eff with
    | Exit.Error
        (Cause.Suppressed
          {
            primary = Cause.Die primary;
            finalizer = Cause.Finalizer.Die finalizer;
          }) ->
        Alcotest.(check bool) "primary exn" true (primary.exn == body_exn);
        Alcotest.(check (option string)) "primary span" (Some "body.leaf")
          primary.span_name;
        Alcotest.(check bool) "finalizer exn" true
          (finalizer.exn == release_exn);
        Alcotest.(check (option string)) "finalizer span" (Some "release.leaf")
          finalizer.span_name;
        Alcotest.(check (option string)) "finalizer annotation" (Some "release")
          (List.assoc_opt "phase" finalizer.annotations)
    | Exit.Error cause ->
        Alcotest.failf "unexpected cause: %a" (Cause.pp Format.pp_print_string)
          cause
    | Exit.Ok _ -> Alcotest.fail "expected finalizer Die"

  let test_runtime_concurrent_child_die_captures_diagnostics () =
    B.with_runtime @@ fun ctx rt ->
    let left_ready, left_resolver = B.create_promise () in
    let right_ready, right_resolver = B.create_promise () in
    let child name own_ready other_ready =
      Effect.named name
        (Effect.sync (fun () -> B.resolve own_ready ())
        |> Effect.bind (fun () -> B.await_effect other_ready)
        |> Effect.bind (fun () -> Effect.sync (fun () -> raise (Failure name))))
      |> Effect.annotate ~key:"branch" ~value:name
      |> Effect.named (name ^ ".span")
    in
    let eff =
      Effect.par
        (child "left" left_resolver right_ready)
        (child "right" right_resolver left_ready)
    in
    match B.await (B.fork_run ctx rt eff) with
    | Exit.Error (Cause.Concurrent causes) ->
        let dies : Cause.die list =
          List.filter_map
            (function Cause.Die die -> Some die | _ -> None)
            causes
        in
        Alcotest.(check (list string)) "child spans"
          [ "left"; "right" ]
          (dies
          |> List.map (fun die -> Option.value die.Cause.span_name ~default:"")
          |> List.sort String.compare);
        List.iter
          (fun die ->
            let expected =
              match die.Cause.span_name with
              | Some "left" -> Some "left"
              | Some "right" -> Some "right"
              | _ -> None
            in
            Alcotest.(check (option string)) "branch annotation" expected
              (List.assoc_opt "branch" die.Cause.annotations))
          dies
    | Exit.Error cause ->
        Alcotest.failf "expected concurrent Die causes, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "expected concurrent child defects"

  let test_runtime_exit_fail_die_interrupt () =
    B.with_runtime @@ fun _ctx rt ->
    let die = Failure "boom" in
    let fail_exit = B.run rt (Effect.fail "bad") in
    let die_exit =
      B.run rt (Effect.named "die" (Effect.sync (fun () -> raise die)))
    in
    let interrupt_exit =
      B.run rt (Effect.named "interrupt" (runtime_interrupt_effect ()))
    in
    expect_typed_failure_eq Alcotest.string fail_exit "bad";
    (match die_exit with
    | Exit.Error (Cause.Die { exn; _ }) when exn == die -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected Die, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected Die");
    match interrupt_exit with
    | Exit.Error (Cause.Interrupt None) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected Interrupt, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected Interrupt"

  let test_effect_catch_does_not_catch_defect () =
    B.with_runtime @@ fun _ctx rt ->
    let defect = Failure "body defect" in
    let handler_ran = ref false in
    let body : (string, [ `Expected ]) Effect.t =
      Effect.named "defect" (Effect.sync (fun () -> raise defect))
    in
    let eff =
      body
      |> Effect.catch (fun (`Expected : [ `Expected ]) ->
             Effect.sync (fun () -> handler_ran := true)
             |> Effect.map (fun () -> "caught"))
    in
    match B.run rt eff with
    | Exit.Error (Cause.Die die) when die.exn == defect ->
        Alcotest.(check bool) "handler skipped" false !handler_ran
    | Exit.Error cause ->
        Alcotest.failf "expected defect, got %a"
          (Cause.pp (fun fmt `Expected ->
               Format.pp_print_string fmt "expected"))
          cause
    | Exit.Ok value -> Alcotest.failf "catch swallowed defect as %S" value

  let test_effect_catch_does_not_catch_interrupt () =
    B.with_runtime @@ fun _ctx rt ->
    let eff =
      Effect.named "interrupt" (runtime_interrupt_effect ())
      |> Effect.catch (fun (_ : string) -> Effect.pure "caught")
    in
    match B.run rt eff with
    | Exit.Error (Cause.Interrupt None) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected Interrupt, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok value -> Alcotest.failf "catch swallowed interrupt as %S" value

  let test_effect_catch_does_not_catch_cancellation () =
    B.with_runtime @@ fun ctx rt ->
    let entered, entered_resolver = B.create_promise () in
    let handler_ran = ref false in
    let body : (unit, string) Effect.t =
      Effect.sync (fun () -> B.resolve entered_resolver ())
      |> Effect.bind (fun () -> B.await_cancel_effect ())
    in
    let eff =
      body
      |> Effect.catch (fun (_ : string) ->
             Effect.sync (fun () -> handler_ran := true))
    in
    let fiber = B.fork_run_cancelable ctx rt eff in
    ignore (B.await entered : unit);
    B.cancel_fiber fiber;
    expect_interrupted "catch" (B.await_cancelable fiber);
    Alcotest.(check bool) "handler skipped" false !handler_ran

  let test_effect_map_error_does_not_map_cancellation () =
    B.with_runtime @@ fun ctx rt ->
    let entered, entered_resolver = B.create_promise () in
    let mapper_ran = ref false in
    let body : (unit, string) Effect.t =
      Effect.sync (fun () -> B.resolve entered_resolver ())
      |> Effect.bind (fun () -> B.await_cancel_effect ())
    in
    let eff =
      body
      |> Effect.map_error (fun err ->
             mapper_ran := true;
             `Mapped err)
    in
    let fiber = B.fork_run_cancelable ctx rt eff in
    ignore (B.await entered : unit);
    B.cancel_fiber fiber;
    expect_interrupted "map_error" (B.await_cancelable fiber);
    Alcotest.(check bool) "mapper skipped" false !mapper_ran

  let test_effect_finally_success_and_failure () =
    B.with_runtime @@ fun _ctx rt ->
    let finalized = ref 0 in
    let cleanup = Effect.sync (fun () -> incr finalized) in
    let success = Effect.pure 42 |> Effect.finally cleanup in
    let failure = Effect.fail "body" |> Effect.finally cleanup in
    Alcotest.(check int) "success value" 42 (run_ok rt success);
    expect_typed_failure_eq Alcotest.string (B.run rt failure) "body";
    Alcotest.(check int) "cleanup count" 2 !finalized

  let test_effect_finally_cleanup_failure_after_success () =
    B.with_runtime @@ fun _ctx rt ->
    let eff =
      Effect.pure 42
      |> Effect.finally (Effect.fail "cleanup")
      |> Effect.catch (fun (_ : string) -> Effect.pure 0)
    in
    match B.run rt eff with
    | Exit.Error (Cause.Finalizer (Cause.Finalizer.Fail "<typed failure>")) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected finalizer cleanup failure, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "catch erased cleanup failure after success"

  let test_effect_finally_suppresses_cleanup_failure () =
    B.with_runtime @@ fun _ctx rt ->
    let eff =
      Effect.fail "body"
      |> Effect.finally (Effect.fail "cleanup")
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
        Alcotest.failf "expected suppressed cleanup failure, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok () -> Alcotest.fail "expected suppressed failure"

  let test_effect_finally_runs_after_defect () =
    B.with_runtime @@ fun _ctx rt ->
    let cleaned = ref false in
    let eff =
      Effect.sync (fun () -> failwith "body defect")
      |> Effect.finally (Effect.sync (fun () -> cleaned := true))
    in
    (match B.run rt eff with
    | Exit.Error (Cause.Die _) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected body defect, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "expected body defect");
    Alcotest.(check bool) "cleaned" true !cleaned

  let test_effect_finally_suppresses_cleanup_failure_after_defect () =
    B.with_runtime @@ fun _ctx rt ->
    let eff =
      Effect.sync (fun () -> failwith "body defect")
      |> Effect.finally (Effect.fail "cleanup")
    in
    match B.run rt eff with
    | Exit.Error
        (Cause.Suppressed
          { primary = Cause.Die _; finalizer = Cause.Finalizer.Fail "<typed failure>" }) ->
        ()
    | Exit.Error cause ->
        Alcotest.failf "expected suppressed cleanup failure after defect, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "expected suppressed cleanup failure after defect"

  let test_effect_finally_runs_on_cancellation () =
    B.with_test_clock @@ fun ctx clock rt ->
    let finalized = ref false in
    let slow =
      Effect.delay (Duration.ms 1_000) (Effect.pure "slow")
      |> Effect.finally (Effect.sync (fun () -> finalized := true))
    in
    let fast =
      Effect.sync (fun () -> wait_for_sleepers clock 1)
      |> Effect.map (fun () -> "fast")
    in
    let promise = B.fork_run ctx rt (Effect.race [ slow; fast ]) in
    check_exit_ok Alcotest.string "fast wins" "fast" (B.await promise);
    Alcotest.(check bool) "cleanup ran" true !finalized

  let test_effect_on_exit_observes_success_failure_and_defect () =
    B.with_runtime @@ fun _ctx rt ->
    let label_int_exit = function
      | Exit.Ok value -> "ok:" ^ string_of_int value
      | Exit.Error (Cause.Fail err) -> "fail:" ^ err
      | Exit.Error (Cause.Die _) -> "die"
      | Exit.Error (Cause.Interrupt _) -> "interrupt"
      | Exit.Error _ -> "other"
    in
    let success_seen = ref [] in
    let success =
      Effect.pure 42
      |> Effect.on_exit (fun exit ->
             Effect.sync (fun () ->
                 success_seen := label_int_exit exit :: !success_seen))
    in
    check_exit_ok Alcotest.int "success value" 42 (B.run rt success);
    Alcotest.(check (list string))
      "success exit" [ "ok:42" ] (List.rev !success_seen);

    let failure_seen = ref [] in
    let failure : (int, string) Effect.t =
      Effect.fail "body"
      |> Effect.on_exit (fun exit ->
             Effect.sync (fun () ->
                 failure_seen := label_int_exit exit :: !failure_seen))
    in
    expect_typed_failure_eq Alcotest.string (B.run rt failure) "body";
    Alcotest.(check (list string))
      "failure exit" [ "fail:body" ] (List.rev !failure_seen);

    let defect_seen = ref [] in
    let defect : (int, string) Effect.t =
      Effect.sync (fun () -> failwith "body defect")
      |> Effect.on_exit (fun exit ->
             Effect.sync (fun () ->
                 defect_seen := label_int_exit exit :: !defect_seen))
    in
    (match B.run rt defect with
    | Exit.Error (Cause.Die _) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected defect, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "expected defect");
    Alcotest.(check (list string)) "defect exit" [ "die" ] (List.rev !defect_seen)

  let test_effect_on_exit_observes_interruption () =
    B.with_runtime @@ fun ctx rt ->
    let entered, entered_resolver = B.create_promise () in
    let observed = ref [] in
    let label_unit_exit = function
      | Exit.Ok () -> "ok"
      | Exit.Error (Cause.Interrupt _) -> "interrupt"
      | Exit.Error _ -> "other"
    in
    let body : (unit, string) Effect.t =
      Effect.sync (fun () -> B.resolve entered_resolver ())
      |> Effect.bind (fun () -> B.await_cancel_effect ())
    in
    let eff =
      body
      |> Effect.on_exit (fun exit ->
             Effect.sync (fun () ->
                 observed := label_unit_exit exit :: !observed))
    in
    let fiber = B.fork_run_cancelable ctx rt eff in
    ignore (B.await entered : unit);
    B.cancel_fiber fiber;
    expect_interrupted "on_exit" (B.await_cancelable fiber);
    Alcotest.(check (list string))
      "interruption exit" [ "interrupt" ] (List.rev !observed)

  let test_effect_on_exit_cleanup_failure_reporting () =
    B.with_runtime @@ fun _ctx rt ->
    let success =
      Effect.pure 1
      |> Effect.on_exit (fun _ -> Effect.fail "cleanup")
    in
    (match B.run rt success with
    | Exit.Error (Cause.Finalizer (Cause.Finalizer.Fail "<typed failure>")) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected finalizer cleanup failure, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "expected finalizer cleanup failure");

    let failure : (int, string) Effect.t =
      Effect.fail "body"
      |> Effect.on_exit (fun _ -> Effect.fail "cleanup")
    in
    match B.run rt failure with
    | Exit.Error
        (Cause.Suppressed
          {
            primary = Cause.Fail "body";
            finalizer = Cause.Finalizer.Fail "<typed failure>";
          }) ->
        ()
    | Exit.Error cause ->
        Alcotest.failf "expected suppressed cleanup failure, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "expected suppressed cleanup failure"

  let test_effect_selective_cleanup_success_noop () =
    B.with_runtime @@ fun _ctx rt ->
    let on_error_ran = ref false in
    let on_interrupt_ran = ref false in
    let eff =
      Effect.pure 1
      |> Effect.on_error (fun _cause ->
             Effect.sync (fun () -> on_error_ran := true))
      |> Effect.on_interrupt (fun _interrupt ->
             Effect.sync (fun () -> on_interrupt_ran := true))
    in
    check_exit_ok Alcotest.int "success value" 1 (B.run rt eff);
    Alcotest.(check bool) "on_error skipped success" false !on_error_ran;
    Alcotest.(check bool)
      "on_interrupt skipped success" false !on_interrupt_ran

  let test_effect_on_error_observes_typed_defect_and_suppressed () =
    B.with_runtime @@ fun _ctx rt ->
    let label_error_cause = function
      | Cause.Fail err -> "fail:" ^ err
      | Cause.Die _ -> "die"
      | Cause.Interrupt _ -> "interrupt"
      | Cause.Sequential _ -> "sequential"
      | Cause.Concurrent _ -> "concurrent"
      | Cause.Finalizer _ -> "finalizer"
      | Cause.Suppressed _ -> "suppressed"
    in
    let typed_seen = ref [] in
    let typed : (int, string) Effect.t =
      Effect.fail "body"
      |> Effect.on_error (fun cause ->
             Effect.sync (fun () ->
                 typed_seen := label_error_cause cause :: !typed_seen))
    in
    expect_typed_failure_eq Alcotest.string (B.run rt typed) "body";
    Alcotest.(check (list string))
      "typed failure observed" [ "fail:body" ] (List.rev !typed_seen);

    let defect_seen = ref [] in
    let defect : (int, string) Effect.t =
      Effect.sync (fun () -> failwith "body defect")
      |> Effect.on_error (fun cause ->
             Effect.sync (fun () ->
                 defect_seen := label_error_cause cause :: !defect_seen))
    in
    (match B.run rt defect with
    | Exit.Error (Cause.Die _) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected defect, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "expected defect");
    Alcotest.(check (list string))
      "defect observed" [ "die" ] (List.rev !defect_seen);

    let suppressed_seen = ref [] in
    let suppressed : (int, string) Effect.t =
      (Effect.fail "body" |> Effect.finally (Effect.fail "cleanup"))
      |> Effect.on_error (fun cause ->
             Effect.sync (fun () ->
                 suppressed_seen := label_error_cause cause :: !suppressed_seen))
    in
    (match B.run rt suppressed with
    | Exit.Error (Cause.Suppressed _) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected suppressed failure, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "expected suppressed failure");
    Alcotest.(check (list string))
      "suppressed failure observed" [ "suppressed" ] (List.rev !suppressed_seen)

  let test_effect_on_error_skips_interruption () =
    B.with_runtime @@ fun ctx rt ->
    let entered, entered_resolver = B.create_promise () in
    let observed = ref false in
    let body : (unit, string) Effect.t =
      Effect.sync (fun () -> B.resolve entered_resolver ())
      |> Effect.bind (fun () -> B.await_cancel_effect ())
    in
    let eff =
      body
      |> Effect.on_error (fun _cause ->
             Effect.sync (fun () -> observed := true))
    in
    let fiber = B.fork_run_cancelable ctx rt eff in
    ignore (B.await entered : unit);
    B.cancel_fiber fiber;
    expect_interrupted "on_error" (B.await_cancelable fiber);
    Alcotest.(check bool) "on_error skipped interruption" false !observed

  let test_effect_on_interrupt_observes_interruption () =
    B.with_runtime @@ fun ctx rt ->
    let entered, entered_resolver = B.create_promise () in
    let cancellation_seen = ref [] in
    let label_interrupt = function None -> "none" | Some _ -> "some" in
    let body : (unit, string) Effect.t =
      Effect.sync (fun () -> B.resolve entered_resolver ())
      |> Effect.bind (fun () -> B.await_cancel_effect ())
    in
    let cancelled =
      body
      |> Effect.on_interrupt (fun interrupt ->
             Effect.sync (fun () ->
                 cancellation_seen :=
                   label_interrupt interrupt :: !cancellation_seen))
    in
    let fiber = B.fork_run_cancelable ctx rt cancelled in
    ignore (B.await entered : unit);
    B.cancel_fiber fiber;
    expect_interrupted "on_interrupt" (B.await_cancelable fiber);
    Alcotest.(check (list string))
      "anonymous cancellation observed" [ "none" ] (List.rev !cancellation_seen);

    let first = Cause.fresh_interrupt_id () in
    let second = Cause.fresh_interrupt_id () in
    let observed_id : Cause.interrupt_id option ref = ref None in
    let composite =
      effect_error_cause
        (Cause.concurrent
           [ Cause.interrupt_with_id first; Cause.interrupt_with_id second ])
      |> Effect.on_interrupt (fun interrupt ->
             Effect.sync (fun () -> observed_id := interrupt))
    in
    (match B.run rt composite with
    | Exit.Error cause when Cause.is_interrupt_only cause -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected interruption-only cause, got %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected interruption-only cause");
    (match !observed_id with
    | Some id when Cause.equal_interrupt_id id first -> ()
    | Some _ -> Alcotest.fail "on_interrupt used a later interrupt id"
    | None -> Alcotest.fail "on_interrupt did not pass an interrupt id")

  let test_effect_selective_cleanup_failure_reporting () =
    B.with_runtime @@ fun _ctx rt ->
    let on_error : (int, string) Effect.t =
      Effect.fail "body"
      |> Effect.on_error (fun _cause -> Effect.fail "cleanup")
    in
    (match B.run rt on_error with
    | Exit.Error
        (Cause.Suppressed
          {
            primary = Cause.Fail "body";
            finalizer = Cause.Finalizer.Fail "<typed failure>";
          }) ->
        ()
    | Exit.Error cause ->
        Alcotest.failf "expected suppressed on_error cleanup failure, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "expected suppressed on_error cleanup failure");

    let on_interrupt : (int, string) Effect.t =
      effect_error_cause Cause.interrupt
      |> Effect.on_interrupt (fun _interrupt -> Effect.fail "cleanup")
    in
    match B.run rt on_interrupt with
    | Exit.Error
        (Cause.Suppressed
          {
            primary = Cause.Interrupt _;
            finalizer = Cause.Finalizer.Fail "<typed failure>";
          }) ->
        ()
    | Exit.Error cause ->
        Alcotest.failf "expected suppressed on_interrupt cleanup failure, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ ->
        Alcotest.fail "expected suppressed on_interrupt cleanup failure"

  let test_acquire_use_release_exit_observes_success_failure_and_defect () =
    B.with_runtime @@ fun _ctx rt ->
    let label_int_exit = function
      | Exit.Ok value -> "ok:" ^ string_of_int value
      | Exit.Error (Cause.Fail err) -> "fail:" ^ err
      | Exit.Error (Cause.Die _) -> "die"
      | Exit.Error (Cause.Interrupt _) -> "interrupt"
      | Exit.Error _ -> "other"
    in
    let success_seen = ref [] in
    let success =
      Effect.acquire_use_release_exit ~acquire:(Effect.pure "resource")
        ~release:(fun _resource exit ->
          Effect.sync (fun () ->
              success_seen := label_int_exit exit :: !success_seen))
        (fun _resource -> Effect.pure 7)
    in
    check_exit_ok Alcotest.int "success value" 7 (B.run rt success);
    Alcotest.(check (list string))
      "release saw success" [ "ok:7" ] (List.rev !success_seen);

    let failure_seen = ref [] in
    let failure : (int, string) Effect.t =
      Effect.acquire_use_release_exit ~acquire:(Effect.pure "resource")
        ~release:(fun _resource exit ->
          Effect.sync (fun () ->
              failure_seen := label_int_exit exit :: !failure_seen))
        (fun _resource -> Effect.fail "body")
    in
    expect_typed_failure_eq Alcotest.string (B.run rt failure) "body";
    Alcotest.(check (list string))
      "release saw failure" [ "fail:body" ] (List.rev !failure_seen);

    let defect_seen = ref [] in
    let defect : (int, string) Effect.t =
      Effect.acquire_use_release_exit ~acquire:(Effect.pure "resource")
        ~release:(fun _resource exit ->
          Effect.sync (fun () ->
              defect_seen := label_int_exit exit :: !defect_seen))
        (fun _resource -> Effect.sync (fun () -> failwith "body defect"))
    in
    (match B.run rt defect with
    | Exit.Error (Cause.Die _) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected defect, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "expected defect");
    Alcotest.(check (list string))
      "release saw defect" [ "die" ] (List.rev !defect_seen)

  let test_acquire_use_release_exit_observes_interruption () =
    B.with_runtime @@ fun ctx rt ->
    let entered, entered_resolver = B.create_promise () in
    let observed = ref [] in
    let label_unit_exit = function
      | Exit.Ok () -> "ok"
      | Exit.Error (Cause.Interrupt _) -> "interrupt"
      | Exit.Error _ -> "other"
    in
    let body () : (unit, string) Effect.t =
      Effect.sync (fun () -> B.resolve entered_resolver ())
      |> Effect.bind (fun () -> B.await_cancel_effect ())
    in
    let eff =
      Effect.acquire_use_release_exit ~acquire:Effect.unit
        ~release:(fun () exit ->
          Effect.sync (fun () -> observed := label_unit_exit exit :: !observed))
        body
    in
    let fiber = B.fork_run_cancelable ctx rt eff in
    ignore (B.await entered : unit);
    B.cancel_fiber fiber;
    expect_interrupted "acquire_use_release_exit" (B.await_cancelable fiber);
    Alcotest.(check (list string))
      "release saw interruption" [ "interrupt" ] (List.rev !observed)

  let test_acquire_use_release_exit_release_failure_reporting () =
    B.with_runtime @@ fun _ctx rt ->
    let success =
      Effect.acquire_use_release_exit ~acquire:Effect.unit
        ~release:(fun () _exit -> Effect.fail "release")
        (fun () -> Effect.pure 1)
    in
    (match B.run rt success with
    | Exit.Error (Cause.Finalizer (Cause.Finalizer.Fail "<typed failure>")) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected finalizer release failure, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "expected finalizer release failure");

    let failure : (int, string) Effect.t =
      Effect.acquire_use_release_exit ~acquire:Effect.unit
        ~release:(fun () _exit -> Effect.fail "release")
        (fun () -> Effect.fail "body")
    in
    match B.run rt failure with
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
    | Exit.Ok _ -> Alcotest.fail "expected suppressed release failure"

  let test_with_resource_exit_alias_success () =
    B.with_runtime @@ fun _ctx rt ->
    let released = ref false in
    let eff =
      Effect.with_resource_exit ~acquire:(Effect.pure "resource")
        ~release:(fun resource exit ->
          Effect.sync (fun () ->
              match (resource, exit) with
              | "resource", Exit.Ok 3 -> released := true
              | _ -> Alcotest.fail "unexpected release input"))
        (fun _resource -> Effect.pure 3)
    in
    check_exit_ok Alcotest.int "alias value" 3 (B.run rt eff);
    Alcotest.(check bool) "alias released" true !released

  let test_effect_catch_preserves_suppressed_finalizer_failure () =
    B.with_runtime @@ fun _ctx rt ->
    let handler_ran = ref false in
    let eff =
      Effect.fail `Body
      |> Effect.finally (Effect.fail `Cleanup)
      |> Effect.catch (function
           | `Body ->
               Effect.sync (fun () -> handler_ran := true)
               |> Effect.map (fun () -> `Caught))
    in
    match B.run rt eff with
    | Exit.Error (Cause.Finalizer (Cause.Finalizer.Fail "<typed failure>")) ->
        Alcotest.(check bool)
          "handler skipped because finalizer failure keeps eff failed" false
          !handler_ran
    | Exit.Ok `Caught ->
        Alcotest.fail "catch erased the finalizer typed failure"
    | Exit.Error cause ->
        Alcotest.failf "expected finalizer typed failure to remain, got %a"
          (Cause.pp (fun fmt -> function
            | `Body -> Format.pp_print_string fmt "body"
            | `Cleanup -> Format.pp_print_string fmt "cleanup"))
          cause

  let test_effect_catch_preserves_suppressed_finalizer_defect () =
    B.with_runtime @@ fun _ctx rt ->
    let defect = Failure "cleanup defect" in
    let eff =
      Effect.fail "body"
      |> Effect.finally (Effect.sync (fun () -> raise defect))
      |> Effect.catch (fun (_ : string) -> Effect.pure "caught")
    in
    match B.run rt eff with
    | Exit.Error (Cause.Finalizer (Cause.Finalizer.Die { exn; _ }))
      when exn == defect ->
        ()
    | Exit.Error cause ->
        Alcotest.failf "expected finalizer defect, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok value -> Alcotest.failf "catch swallowed defect as %S" value

  let test_effect_catch_strips_typed_primary_before_finalizer () =
    B.with_runtime @@ fun _ctx rt ->
    let handler_ran = ref false in
    let eff =
      Effect.fail `Old_err
      |> Effect.finally (Effect.fail `Old_cleanup)
      |> Effect.catch (function
           | `Old_err | `Old_cleanup ->
               Effect.sync (fun () -> handler_ran := true)
               |> Effect.map (fun () -> "handled"))
    in
    match B.run rt eff with
    | Exit.Error (Cause.Finalizer (Cause.Finalizer.Fail "<typed failure>")) ->
        Alcotest.(check bool)
          "handler skipped because finalizer failure remains" false !handler_ran
    | Exit.Ok _ -> Alcotest.fail "unexpected Ok value"
    | Exit.Error cause ->
        Alcotest.failf "expected only finalizer failure after catch, got %a"
          (Cause.pp (fun fmt (_ : string) -> Format.pp_print_string fmt "<new>"))
          cause

  let test_effect_catch_composite_typed_failure_no_old_payloads () =
    B.with_runtime @@ fun _ctx rt ->
    let handled = ref [] in
    let eff =
      Effect.all
        [ Effect.fail `Fiber_a_err; Effect.fail `Fiber_b_err ]
      |> Effect.catch (function
           | (`Fiber_a_err as error) | (`Fiber_b_err as error) ->
               Effect.sync (fun () -> handled := error :: !handled)
               |> Effect.map (fun () -> [ () ]))
    in
    match B.run rt eff with
    | Exit.Ok [ () ] ->
        Alcotest.(check int)
          "one handler invocation for composite typed cause" 1
          (List.length !handled)
    | Exit.Ok _ -> Alcotest.fail "unexpected Ok value"
    | Exit.Error cause ->
        Alcotest.failf "catch leaked old typed payloads through %a"
          (Cause.pp (fun fmt (_ : string) -> Format.pp_print_string fmt "<new>"))
          cause

  let test_effect_catch_invokes_one_handler_for_concurrent_typed_failure () =
    B.with_runtime @@ fun ctx rt ->
    let gate, gate_resolver = B.create_promise () in
    let left_ready, left_ready_resolver = B.create_promise () in
    let right_ready, right_ready_resolver = B.create_promise () in
    let child ready_resolver error =
      Effect.sync (fun () -> B.resolve ready_resolver ())
      |> Effect.bind (fun () -> B.await_effect gate)
      |> Effect.bind (fun () -> Effect.fail error)
    in
    let handled = ref [] in
    let eff =
      Effect.all
        [ child left_ready_resolver `Left; child right_ready_resolver `Right ]
      |> Effect.catch (fun error ->
             Effect.sync (fun () -> handled := error :: !handled)
             |> Effect.bind (fun () -> Effect.fail `Handler_failed))
    in
    let promise = B.fork_run ctx rt eff in
    ignore (B.await left_ready : unit);
    ignore (B.await right_ready : unit);
    B.resolve gate_resolver ();
    expect_typed_failure_eq
      (Alcotest.testable
         (fun fmt `Handler_failed -> Format.pp_print_string fmt "handler_failed")
         ( = ))
      (B.await promise) `Handler_failed;
    Alcotest.(check int)
      "catch handler invoked once for composite typed cause" 1
      (List.length !handled)

  let test_effect_catch_preserves_concurrent_defect () =
    B.with_runtime @@ fun ctx rt ->
    let defect = Failure "concurrent defect" in
    let handler_ran = ref false in
    let gate, gate_resolver = B.create_promise () in
    let typed_ready, typed_ready_resolver = B.create_promise () in
    let die_ready, die_ready_resolver = B.create_promise () in
    let wait ready_resolver =
      Effect.sync (fun () -> B.resolve ready_resolver ())
      |> Effect.bind (fun () -> B.await_effect gate)
    in
    let typed = wait typed_ready_resolver |> Effect.bind (fun () -> Effect.fail "typed") in
    let die =
      wait die_ready_resolver
      |> Effect.bind (fun () -> Effect.sync (fun () -> raise defect))
    in
    let eff =
      Effect.all [ typed; die ]
      |> Effect.catch (fun (_ : string) ->
             Effect.sync (fun () -> handler_ran := true)
             |> Effect.map (fun () -> [ () ]))
    in
    let promise = B.fork_run ctx rt eff in
    ignore (B.await typed_ready : unit);
    ignore (B.await die_ready : unit);
    B.resolve gate_resolver ();
    match B.await promise with
    | Exit.Error (Cause.Die { exn; _ }) when exn == defect ->
        Alcotest.(check bool)
          "handler skipped because defect keeps eff failed" false !handler_ran
    | Exit.Error cause ->
        Alcotest.failf "expected concurrent defect, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "catch swallowed concurrent defect"

  let test_cause_empty_aggregations_reject () =
    Alcotest.check_raises "empty sequential"
      (Invalid_argument "Cause.sequential: empty")
      (fun () -> ignore (Cause.sequential []));
    Alcotest.check_raises "empty concurrent"
      (Invalid_argument "Cause.concurrent: empty")
      (fun () -> ignore (Cause.concurrent []))

  let test_cause_diagnostic_equal_compares_die_payloads () =
    let left =
      Cause.die_with_diagnostics ~span_name:"span"
        ~annotations:[ ("request.id", "a") ] (Failure "same")
    in
    let right =
      Cause.die_with_diagnostics ~span_name:"span"
        ~annotations:[ ("request.id", "a") ] (Failure "same")
    in
    let different = Cause.die (Failure "different") in
    Alcotest.(check bool) "identity equality stays strict" false
      (Cause.equal String.equal left right);
    Alcotest.(check bool) "diagnostic equality matches payload" true
      (Cause.diagnostic_equal String.equal left right);
    Alcotest.(check bool) "diagnostic equality checks message" false
      (Cause.diagnostic_equal String.equal left different)

  let test_runtime_user_exit_is_defect () =
    B.with_runtime @@ fun _ctx rt ->
    let result =
      B.run rt
        (Effect.named "user.exit" (Effect.sync (fun () -> raise Stdlib.Exit)))
    in
    match result with
    | Exit.Error (Cause.Die { exn = Stdlib.Exit; _ }) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected Stdlib.Exit as Die, got %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok () -> Alcotest.fail "expected Stdlib.Exit to fail"

  let test_cause_to_portable_materializes_diagnostics () =
    let backtrace = Printexc.get_callstack 4 in
    let raw =
      Cause.suppressed ~primary:(Cause.fail "typed")
        ~finalizer:
          (Cause.finalizer_of_cause Fun.id
             (Cause.die_with_diagnostics ~backtrace ~span_name:"release"
                ~annotations:[ ("phase", "release") ] (Failure "boom")))
    in
    match Cause.to_portable Fun.id raw with
    | Cause.Portable.Suppressed
        {
          primary = Cause.Portable.Fail "typed";
          finalizer =
            Cause.Portable.Finalizer.Die
              {
                message = "Failure(\"boom\")";
                backtrace = Some stack;
                span_name = Some "release";
                annotations = [ ("phase", "release") ];
                _;
              };
        } ->
        Alcotest.(check bool) "stack materialized" true (String.length stack > 0)
    | portable ->
        Alcotest.failf "unexpected portable cause: %a"
          (Cause.Portable.pp Format.pp_print_string)
          portable

  let test_explicit_dependency_passing () =
    B.with_runtime @@ fun _ctx rt ->
    let log_calls = ref [] in
    let deps =
      {
        add = (fun n -> n + 1);
        mul = (fun n -> n * 2);
      }
    in
    let db_query s = "row:" ^ s in
    let log_info m = log_calls := m :: !log_calls in
    let services =
      object
        method query = db_query
        method info = log_info
      end
    in
    let b msg = Effect.named "log" (Effect.sync (fun () -> services#info msg)) in
    let c id =
      Effect.named "db"
        (Effect.sync (fun () -> services#query (string_of_int (deps.add id))))
    in
    let a id =
      let open Effect in
      let user_id = deps.add id in
      bind (fun () -> c id) (b ("fetching " ^ string_of_int user_id))
    in
    match B.run rt (a 41) with
    | Exit.Error cause ->
        Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok value ->
        Alcotest.(check string) "db result" "row:42" value;
        Alcotest.(check (list string))
          "log calls" [ "fetching 42" ] (List.rev !log_calls)

  let test_par_returns_both_successes () =
    B.with_runtime @@ fun _ctx rt ->
    let result = run_ok rt (Effect.par (Effect.pure 1) (Effect.pure 2)) in
    Alcotest.(check (pair int int)) "par returns pair" (1, 2) result

  let test_par_keeps_heterogeneous_successes_private () =
    B.with_runtime @@ fun _ctx rt ->
    let result = run_ok rt (Effect.par (Effect.pure 1) (Effect.pure "two")) in
    Alcotest.(check (pair int string)) "par returns typed pair" (1, "two") result

  let test_all_collects_in_input_order () =
    B.with_runtime @@ fun _ctx rt ->
    let result =
      run_ok rt (Effect.all [ Effect.pure 1; Effect.pure 2; Effect.pure 3 ])
    in
    Alcotest.(check (list int)) "all order" [ 1; 2; 3 ] result

  let test_all_empty_returns_empty_list () =
    B.with_runtime @@ fun _ctx rt ->
    Alcotest.(check (list int)) "empty" [] (run_ok rt (Effect.all []))

  let test_all_fail_fast () =
    B.with_runtime @@ fun _ctx rt ->
    let exit =
      B.run rt (Effect.all [ Effect.pure 1; Effect.fail "boom"; Effect.pure 3 ])
    in
    check_exit_error string_cause "all cause" (Cause.Fail "boom") exit

  let test_all_settled_collects_successes_and_failures () =
    B.with_runtime @@ fun _ctx rt ->
    let result =
      run_ok rt
        (Effect.all_settled
           [ Effect.pure 1; Effect.fail `Boom; Effect.pure 3 ])
    in
    match result with
    | [ Ok 1; Error (Cause.Fail `Boom); Ok 3 ] -> ()
    | _ -> Alcotest.fail "unexpected all_settled result"

  let test_all_settled_empty () =
    B.with_runtime @@ fun _ctx rt ->
    Alcotest.(check int) "empty" 0
      (List.length (run_ok rt (Effect.all_settled [])))

  let test_for_each_par_success () =
    B.with_runtime @@ fun _ctx rt ->
    let result =
      run_ok rt
        (Effect.for_each_par [ 10; 20; 30 ] (fun x -> Effect.pure (x + 1)))
    in
    Alcotest.(check (list int)) "for_each_par results" [ 11; 21; 31 ] result

  let test_for_each_par_one_fails () =
    B.with_runtime @@ fun _ctx rt ->
    let exit =
      B.run rt
        (Effect.for_each_par [ 1; 2; 3 ] (fun x ->
             if x = 2 then Effect.fail "bad" else Effect.pure x))
    in
    check_exit_error string_cause "for_each_par cause" (Cause.Fail "bad") exit

  let test_for_each_par_bounded_max_one_is_sequential () =
    B.with_runtime @@ fun _ctx rt ->
    let active = ref 0 in
    let max_seen = ref 0 in
    let worker x =
      Effect.named "worker" (Effect.sync (fun () ->
          incr active;
          max_seen := max !max_seen !active;
          decr active;
          x))
    in
    Alcotest.(check (list int)) "results" [ 1; 2; 3 ]
      (run_ok rt (Effect.for_each_par_bounded ~max:1 [ 1; 2; 3 ] worker));
    Alcotest.(check int) "max concurrency" 1 !max_seen

  let test_for_each_par_bounded_rejects_nonpositive_max () =
    Alcotest.check_raises "zero max"
      (Invalid_argument "Effect.for_each_par_bounded: max must be > 0")
      (fun () ->
        ignore
          (Effect.for_each_par_bounded ~max:0 [ 1 ] (fun x -> Effect.pure x)
            : (int list, _) Effect.t));
    Alcotest.check_raises "negative max"
      (Invalid_argument "Effect.for_each_par_bounded: max must be > 0")
      (fun () ->
        ignore
          (Effect.for_each_par_bounded ~max:(-1) [ 1 ] (fun x ->
               Effect.pure x)
            : (int list, _) Effect.t))

  let test_for_each_par_mapper_defect_is_runtime_die () =
    B.with_runtime @@ fun _ctx rt ->
    let mapper_called = ref false in
    let eff =
      try
        Some
          (Effect.for_each_par [ 1 ] (fun _ ->
               mapper_called := true;
               raise (Failure "mapper boom")))
      with Failure msg when String.equal msg "mapper boom" -> None
    in
    Alcotest.(check bool)
      "mapper not called during construction" false !mapper_called;
    match eff with
    | None -> Alcotest.fail "for_each_par forced mapper during construction"
    | Some eff -> (
        match B.run rt eff with
        | Exit.Error (Cause.Die die) ->
            Alcotest.(check string)
              "defect" "Failure(\"mapper boom\")"
              (Printexc.to_string die.exn)
        | Exit.Ok _ -> Alcotest.fail "mapper defect unexpectedly succeeded"
        | Exit.Error cause ->
            Alcotest.failf "expected Die, got %a" (Cause.pp pp_hidden) cause)

  let test_for_each_par_bounded_mapper_defect_is_runtime_die () =
    B.with_runtime @@ fun _ctx rt ->
    let mapper_called = ref false in
    let eff =
      try
        Some
          (Effect.for_each_par_bounded ~max:2 [ 1 ] (fun _ ->
               mapper_called := true;
               raise (Failure "bounded mapper boom")))
      with Failure msg when String.equal msg "bounded mapper boom" -> None
    in
    Alcotest.(check bool)
      "mapper not called during construction" false !mapper_called;
    match eff with
    | None ->
        Alcotest.fail "for_each_par_bounded forced mapper during construction"
    | Some eff -> (
        match B.run rt eff with
        | Exit.Error (Cause.Die die) ->
            Alcotest.(check string)
              "defect" "Failure(\"bounded mapper boom\")"
              (Printexc.to_string die.exn)
        | Exit.Ok _ -> Alcotest.fail "mapper defect unexpectedly succeeded"
        | Exit.Error cause ->
            Alcotest.failf "expected Die, got %a" (Cause.pp pp_hidden) cause)

  let test_all_preserves_input_order_with_out_of_order_completion () =
    B.with_test_clock @@ fun ctx clock rt ->
    let eff =
      Effect.all
        [
          Effect.pure 1 |> Effect.delay (Duration.ms 30);
          Effect.pure 2 |> Effect.delay (Duration.ms 10);
          Effect.pure 3 |> Effect.delay (Duration.ms 20);
        ]
    in
    let promise = B.fork_run ctx rt eff in
    wait_for_sleepers clock 3;
    B.adjust_clock clock (Duration.ms 30);
    check_exit_ok (Alcotest.list Alcotest.int) "input order" [ 1; 2; 3 ]
      (B.await promise)

  let test_all_settled_preserves_input_order_with_out_of_order_completion () =
    B.with_test_clock @@ fun ctx clock rt ->
    let eff =
      Effect.all_settled
        [
          Effect.pure 1 |> Effect.delay (Duration.ms 30);
          Effect.fail `Boom |> Effect.delay (Duration.ms 10);
          Effect.pure 3 |> Effect.delay (Duration.ms 20);
        ]
    in
    let promise = B.fork_run ctx rt eff in
    wait_for_sleepers clock 3;
    B.adjust_clock clock (Duration.ms 30);
    match B.await promise with
    | Exit.Ok [ Ok 1; Error (Cause.Fail `Boom); Ok 3 ] -> ()
    | Exit.Ok _ -> Alcotest.fail "unexpected all_settled result order"
    | Exit.Error cause ->
        Alcotest.failf "expected settled results, got %a" (Cause.pp pp_hidden)
          cause

  let test_all_settled_runs_all_children () =
    B.with_test_clock @@ fun ctx clock rt ->
    let slow_done = ref 0 in
    let slow name =
      Effect.named name (Effect.sync (fun () -> incr slow_done))
      |> Effect.delay (Duration.ms 50)
    in
    let promise =
      B.fork_run ctx rt
        (Effect.all_settled [ Effect.fail `Boom; slow "a"; slow "b" ])
    in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 50);
    ignore
      (B.await promise :
        ((unit, [> `Boom ] Cause.t) result list, _) Exit.t);
    Alcotest.(check int) "slow children completed" 2 !slow_done

  let test_all_settled_timeout_scoped_resource_is_typed () =
    B.with_test_clock @@ fun ctx clock rt ->
    let released = ref 0 in
    let body =
      Effect.scoped
        (Effect.acquire_release ~acquire:(Effect.pure ())
           ~release:(fun () ->
             Effect.named "release" (Effect.sync (fun () -> incr released)))
        |> Effect.bind (fun () ->
               Effect.delay (Duration.seconds 10) Effect.unit))
      |> Effect.timeout (Duration.seconds 5)
    in
    let promise = B.fork_run ctx rt (Effect.all_settled [ body ]) in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.seconds 5);
    match B.await promise with
    | Exit.Ok [ Error (Cause.Fail `Timeout) ] ->
        Alcotest.(check int) "released" 1 !released
    | Exit.Ok [ Error cause ] ->
        Alcotest.failf "expected typed timeout, got %a" (Cause.pp pp_hidden)
          cause
    | Exit.Ok _ -> Alcotest.fail "expected one settled timeout"
    | Exit.Error cause ->
        Alcotest.failf "expected all_settled success, got %a"
          (Cause.pp pp_hidden) cause

  let test_for_each_par_preserves_input_order_with_out_of_order_completion () =
    B.with_test_clock @@ fun ctx clock rt ->
    let worker x =
      let delay =
        match x with 1 -> 30 | 2 -> 10 | 3 -> 20 | _ -> 0
      in
      Effect.pure (x * 10) |> Effect.delay (Duration.ms delay)
    in
    let promise = B.fork_run ctx rt (Effect.for_each_par [ 1; 2; 3 ] worker) in
    wait_for_sleepers clock 3;
    B.adjust_clock clock (Duration.ms 30);
    check_exit_ok (Alcotest.list Alcotest.int) "input order" [ 10; 20; 30 ]
      (B.await promise)

  let test_for_each_par_bounded_caps_concurrency () =
    B.with_test_clock @@ fun ctx clock rt ->
    let active = ref 0 in
    let max_seen = ref 0 in
    let worker x =
      Effect.named "enter" (Effect.sync (fun () ->
          incr active;
          max_seen := max !max_seen !active))
      |> Effect.bind (fun () ->
             Effect.pure x
             |> Effect.delay (Duration.ms 10)
             |> Effect.tap (fun _ ->
                    Effect.named "leave" (Effect.sync (fun () -> decr active))))
    in
    let promise =
      B.fork_run ctx rt
        (Effect.for_each_par_bounded ~max:2 [ 1; 2; 3; 4; 5 ] worker)
    in
    for _ = 1 to 3 do
      wait_for_sleepers clock 1;
      B.adjust_clock clock (Duration.ms 10);
      B.yield ()
    done;
    check_exit_ok (Alcotest.list Alcotest.int) "results" [ 1; 2; 3; 4; 5 ]
      (B.await promise);
    Alcotest.(check int) "max concurrency" 2 !max_seen

  let test_for_each_par_bounded_fail_fast () =
    B.with_test_clock @@ fun ctx clock rt ->
    let slow_done = ref false in
    let worker = function
      | 1 -> Effect.fail "boom"
      | _ ->
          Effect.named "slow" (Effect.sync (fun () -> slow_done := true))
          |> Effect.delay (Duration.ms 10)
    in
    let promise =
      B.fork_run ctx rt
        (Effect.for_each_par_bounded ~max:2 [ 1; 2; 3 ] worker)
    in
    B.yield ();
    check_exit_error string_cause "cause" (Cause.Fail "boom") (B.await promise);
    B.adjust_clock clock (Duration.ms 10);
    B.yield ();
    Alcotest.(check bool) "slow cancelled" false !slow_done

  let test_effect_race_ignores_early_failure_until_success () =
    B.with_test_clock @@ fun ctx clock rt ->
    let delayed_success ms value =
      Effect.pure value |> Effect.delay (Duration.ms ms)
    in
    let eff =
      Effect.race
        [
          Effect.fail `Boom |> Effect.delay Duration.zero;
          delayed_success 200 200;
          delayed_success 100 100;
        ]
    in
    let promise = B.fork_run ctx rt eff in
    wait_for_sleepers clock 2;
    Alcotest.(check int) "race sleepers registered" 2 (B.sleeper_count clock);
    B.adjust_clock clock (Duration.ms 100);
    check_exit_ok Alcotest.int "first success wins" 100 (B.await promise)

  let test_effect_race_cancels_losers_after_first_success () =
    B.with_test_clock @@ fun ctx clock rt ->
    let loser_completed = ref false in
    let winner = Effect.pure "winner" |> Effect.delay (Duration.ms 10) in
    let loser =
      Effect.sync (fun () -> loser_completed := true)
      |> Effect.delay (Duration.ms 100)
      |> Effect.map (fun () -> "loser")
    in
    let promise = B.fork_run ctx rt (Effect.race [ winner; loser ]) in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 10);
    check_exit_ok Alcotest.string "winner" "winner" (B.await promise);
    B.adjust_clock clock (Duration.ms 100);
    B.yield ();
    Alcotest.(check bool) "loser cancelled" false !loser_completed

  let test_effect_race_all_failures_returns_concurrent_causes () =
    B.with_test_clock @@ fun ctx clock rt ->
    let delayed_failure ms error =
      Effect.fail error |> Effect.delay (Duration.ms ms)
    in
    let eff =
      Effect.race [ delayed_failure 0 "first"; delayed_failure 10 "second" ]
    in
    let promise = B.fork_run ctx rt eff in
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 10);
    check_exit_error string_cause "failures combined"
      (Cause.Concurrent [ Cause.Fail "first"; Cause.Fail "second" ])
      (B.await promise)

  let test_effect_race_releases_scoped_loser_resource () =
    B.with_runtime @@ fun _ctx rt ->
    let sem = Semaphore.make ~permits:1 in
    let winner = Effect.pure `Winner in
    let loser = Semaphore.with_permits sem 1 (fun () -> Effect.pure `Loser) in
    let result = run_ok rt (Effect.race [ winner; loser ]) in
    Alcotest.(check bool) "winner wins" true (result = `Winner);
    Alcotest.(check int) "scoped loser permit released, not leaked" 1
      (Semaphore.available sem)

  let test_effect_race_reports_loser_finalizer_failure_after_winner () =
    B.with_test_clock @@ fun ctx clock rt ->
    let acquired, acquired_u = B.create_promise () in
    let release_started = ref false in
    let slow =
      Effect.scoped
        (Effect.acquire_release
           ~acquire:(Effect.sync (fun () -> B.resolve acquired_u ()))
           ~release:(fun () ->
             release_started := true;
             Effect.fail "release")
        |> Effect.bind (fun () ->
               Effect.delay (Duration.ms 1_000) (Effect.pure "slow")))
    in
    let winner = B.await_effect acquired |> Effect.map (fun () -> "winner") in
    let promise = B.fork_run ctx rt (Effect.race [ slow; winner ]) in
    wait_for_sleepers clock 1;
    match B.await promise with
    | Exit.Ok value ->
        Alcotest.failf
          "expected loser finalizer failure after winner, got Ok %S" value
    | Exit.Error cause ->
        check_suppressed_finalizer
          "loser release failure is reported after winner" "<typed failure>"
          cause;
        Alcotest.(check bool)
          "loser finalizer ran before race returned" true !release_started

  let test_effect_race_timeout_during_loser_cleanup_keeps_winner () =
    B.with_test_clock @@ fun ctx clock rt ->
    let sem = Semaphore.make ~permits:1 in
    let release_started, release_started_u = B.create_promise () in
    let release_continue, release_continue_u = B.create_promise () in
    let loser =
      Effect.scoped
        (Effect.acquire_release ~acquire:Effect.unit
           ~release:(fun () ->
             Effect.sync (fun () -> B.try_resolve release_started_u ())
             |> Effect.bind (fun () -> B.await_effect release_continue))
        |> Effect.bind (fun () ->
               Effect.delay (Duration.ms 1_000) (Effect.pure `Loser)))
    in
    let winner = Semaphore.acquire sem 1 |> Effect.map (fun () -> `Winner) in
    let promise =
      B.fork_run ctx rt
        (Effect.race [ loser; winner ]
        |> Effect.timeout_as (Duration.ms 5) ~on_timeout:`Timeout)
    in
    B.await release_started;
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 5);
    B.yield ();
    B.resolve release_continue_u ();
    match B.await promise with
    | Exit.Ok `Winner ->
        Semaphore.release sem 1;
        Alcotest.(check int) "permit returned by caller" 1
          (Semaphore.available sem)
    | Exit.Ok `Loser -> Alcotest.fail "loser won unexpectedly"
    | Exit.Error cause ->
        Alcotest.failf "timeout discarded race winner: %a"
          (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<race>"))
          cause

  let test_par_nested_race_all_failures_baseline () =
    B.with_test_clock @@ fun ctx clock rt ->
    let delayed_failure ms error =
      Effect.fail error |> Effect.delay (Duration.ms ms)
    in
    let nested =
      Effect.race
        [ delayed_failure 0 "race-left"; delayed_failure 10 "race-right" ]
    in
    let promise =
      B.fork_run ctx rt
        (Effect.par nested (Effect.pure () |> Effect.delay (Duration.ms 20)))
    in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 10);
    match B.await promise with
    | Exit.Ok _ -> Alcotest.fail "expected nested race failure"
    | Exit.Error cause -> (
        match cause with
        | Cause.Concurrent causes ->
            Alcotest.(check bool)
              "nested first failure observed" true
              (List.exists
                 (Cause.equal String.equal (Cause.Fail "race-left"))
                 causes);
            Alcotest.(check bool)
              "nested second failure observed" true
              (List.exists
                 (Cause.equal String.equal (Cause.Fail "race-right"))
                 causes)
        | _ ->
            Alcotest.failf "expected Concurrent cause, got %a"
              (Cause.pp Format.pp_print_string) cause)

  let test_par_fail_fast_cancels_sibling () =
    B.with_runtime @@ fun _ctx rt ->
    let other_done = ref false in
    let slow_other =
      B.yield_effect ()
      |> Effect.bind (fun () ->
             Effect.named "slow"
               (Effect.sync (fun () ->
                    other_done := true;
                    99)))
    in
    let exit = B.run rt (Effect.par (Effect.fail "boom") slow_other) in
    check_exit_error string_cause "par cause" (Cause.Fail "boom") exit;
    Alcotest.(check bool) "sibling cancelled before completion" false !other_done

  let test_par_simultaneous_failures_records_concurrent_baseline () =
    B.with_runtime @@ fun ctx rt ->
    let go, release = B.create_promise () in
    let ready = B.create_stream 2 in
    let child name =
      Effect.named name
        (Effect.sync (fun () -> B.stream_add ready name)
        |> Effect.bind (fun () -> B.await_effect go)
        |> Effect.bind (fun () -> Effect.fail name))
    in
    let promise = B.fork_run ctx rt (Effect.par (child "left") (child "right")) in
    let first = B.stream_take ready in
    let second = B.stream_take ready in
    B.resolve release ();
    match B.await promise with
    | Exit.Ok _ -> Alcotest.fail "expected simultaneous failure"
    | Exit.Error cause ->
        check_concurrent_cause "par simultaneous failure baseline" cause;
        Alcotest.(check bool)
          "first child observed" true
          (string_cause_contains first cause);
        Alcotest.(check bool)
          "second child observed" true
          (string_cause_contains second cause)

  let test_par_finalizer_failure_during_sibling_cancellation () =
    B.with_test_clock @@ fun ctx clock rt ->
    let acquired, acquired_u = B.create_promise () in
    let release_started = ref false in
    let slow =
      Effect.scoped
        (Effect.acquire_release
           ~acquire:
             (Effect.named "par.slow.acquire"
                (Effect.sync (fun () -> B.resolve acquired_u ())))
           ~release:(fun () ->
             release_started := true;
             Effect.fail "release")
        |> Effect.bind (fun () -> Effect.delay (Duration.ms 1_000) Effect.unit))
    in
    let body =
      Effect.named "par.body.wait_for_acquire" (B.await_effect acquired)
      |> Effect.bind (fun () -> Effect.fail "body")
    in
    let promise = B.fork_run ctx rt (Effect.par body slow) in
    wait_for_sleepers clock 1;
    match B.await promise with
    | Exit.Ok _ -> Alcotest.fail "expected body/finalizer failure"
    | Exit.Error cause ->
        check_concurrent_cause "par cancellation/finalizer failure" cause;
        Alcotest.(check bool)
          "body failure observed" true
          (string_cause_contains "body" cause);
        check_suppressed_finalizer
          "cancelled sibling release failure is suppressed under interrupt"
          "<typed failure>" cause;
        Alcotest.(check bool)
          "cancelled sibling finalizer ran before par returned" true
          !release_started

  let test_par_catch_recovers_typed_failure_after_sibling_cancel () =
    B.with_test_clock @@ fun ctx _clock rt ->
    let ready, mark_ready = B.create_promise () in
    let go, release = B.create_promise () in
    let failing =
      B.await_effect go |> Effect.bind (fun () -> Effect.fail `My_error)
    in
    let cancelled =
      Effect.sync (fun () -> B.resolve mark_ready ())
      |> Effect.bind (fun () -> B.await_cancel_effect ())
    in
    let eff =
      Effect.par failing cancelled
      |> Effect.map (fun _ -> "unexpected")
      |> Effect.catch (fun (`My_error : [ `My_error ]) ->
             Effect.pure "recovered")
    in
    let promise = B.fork_run ctx rt eff in
    B.await ready;
    B.resolve release ();
    check_exit_ok Alcotest.string "recovered" "recovered" (B.await promise)

  let test_all_catch_recovers_typed_failure_after_sibling_cancel () =
    B.with_test_clock @@ fun ctx _clock rt ->
    let ready, mark_ready = B.create_promise () in
    let go, release = B.create_promise () in
    let failing =
      B.await_effect go |> Effect.bind (fun () -> Effect.fail `My_error)
    in
    let cancelled =
      Effect.sync (fun () -> B.resolve mark_ready ())
      |> Effect.bind (fun () -> B.await_cancel_effect ())
    in
    let eff =
      Effect.all [ failing; cancelled ]
      |> Effect.map (fun _ -> "unexpected")
      |> Effect.catch (fun (`My_error : [ `My_error ]) ->
             Effect.pure "recovered")
    in
    let promise = B.fork_run ctx rt eff in
    B.await ready;
    B.resolve release ();
    check_exit_ok Alcotest.string "recovered" "recovered" (B.await promise)

  let test_all_finalizer_failure_during_sibling_cancellation_baseline () =
    B.with_test_clock @@ fun ctx clock rt ->
    let acquired, acquired_u = B.create_promise () in
    let release_started = ref false in
    let slow =
      Effect.scoped
        (Effect.acquire_release
           ~acquire:
             (Effect.named "slow.acquire"
                (Effect.sync (fun () -> B.resolve acquired_u ())))
           ~release:(fun () ->
             release_started := true;
             Effect.fail "release")
        |> Effect.bind (fun () -> Effect.delay (Duration.ms 1_000) Effect.unit))
    in
    let body =
      Effect.named "body.wait_for_acquire" (B.await_effect acquired)
      |> Effect.bind (fun () -> Effect.fail "body")
    in
    let promise = B.fork_run ctx rt (Effect.all [ body; slow ]) in
    wait_for_sleepers clock 1;
    match B.await promise with
    | Exit.Ok _ -> Alcotest.fail "expected body/finalizer failure"
    | Exit.Error cause ->
        check_concurrent_cause "all cancellation/finalizer failure" cause;
        Alcotest.(check bool)
          "body failure observed" true
          (string_cause_contains "body" cause);
        check_suppressed_finalizer
          "cancelled sibling release failure is suppressed under interrupt"
          "<typed failure>" cause;
        Alcotest.(check bool)
          "cancelled sibling finalizer ran before all returned" true !release_started

  let test_for_each_par_simultaneous_failures_baseline () =
    B.with_runtime @@ fun ctx rt ->
    let go, release = B.create_promise () in
    let ready = B.create_stream 2 in
    let worker name =
      Effect.named ("worker." ^ name)
        (Effect.sync (fun () ->
             if name <> "ok" then B.stream_add ready name;
             name)
        |> Effect.bind (fun name ->
               if name = "ok" then Effect.pure name
               else B.await_effect go |> Effect.bind (fun () -> Effect.fail name)))
    in
    let promise =
      B.fork_run ctx rt (Effect.for_each_par [ "left"; "right"; "ok" ] worker)
    in
    let first = B.stream_take ready in
    let second = B.stream_take ready in
    B.resolve release ();
    match B.await promise with
    | Exit.Ok _ -> Alcotest.fail "expected for_each_par failure"
    | Exit.Error cause ->
        check_concurrent_cause "for_each_par simultaneous baseline" cause;
        Alcotest.(check bool)
          "first item observed" true
          (string_cause_contains first cause);
        Alcotest.(check bool)
          "second item observed" true
          (string_cause_contains second cause)

  let test_for_each_par_finalizer_failure_during_sibling_cancellation () =
    B.with_test_clock @@ fun ctx clock rt ->
    let acquired, acquired_u = B.create_promise () in
    let release_started = ref false in
    let worker = function
      | "slow" ->
          Effect.scoped
            (Effect.acquire_release
               ~acquire:
                 (Effect.named "foreach.slow.acquire"
                    (Effect.sync (fun () -> B.resolve acquired_u ())))
               ~release:(fun () ->
                 release_started := true;
                 Effect.fail "release")
            |> Effect.bind (fun () ->
                   Effect.delay (Duration.ms 1_000) Effect.unit))
      | "body" ->
          Effect.named "foreach.body.wait_for_acquire" (B.await_effect acquired)
          |> Effect.bind (fun () -> Effect.fail "body")
      | _ -> Effect.unit
    in
    let promise =
      B.fork_run ctx rt (Effect.for_each_par [ "body"; "slow" ] worker)
    in
    wait_for_sleepers clock 1;
    match B.await promise with
    | Exit.Ok _ -> Alcotest.fail "expected body/finalizer failure"
    | Exit.Error cause ->
        check_concurrent_cause "for_each_par cancellation/finalizer failure" cause;
        Alcotest.(check bool)
          "body failure observed" true
          (string_cause_contains "body" cause);
        check_suppressed_finalizer
          "cancelled sibling release failure is suppressed under interrupt"
          "<typed failure>" cause;
        Alcotest.(check bool)
          "cancelled sibling finalizer ran before for_each_par returned" true
          !release_started

  let test_effect_race_simultaneous_success_and_failure_returns_winner () =
    B.with_test_clock @@ fun ctx _clock rt ->
    for iteration = 1 to 64 do
      let go, release = B.create_promise () in
      let ready = B.create_stream 2 in
      let child name result =
        Effect.named ("race." ^ name)
          (Effect.sync (fun () -> B.stream_add ready name)
          |> Effect.bind (fun () -> B.await_effect go))
        |> Effect.bind (fun () -> result)
      in
      let promise =
        B.fork_run ctx rt
          (Effect.race
             [
               child "winner" (Effect.pure "winner");
               child "failure" (Effect.fail "failure");
             ])
      in
      ignore (B.stream_take ready : string);
      ignore (B.stream_take ready : string);
      B.resolve release ();
      check_exit_ok Alcotest.string
        (Printf.sprintf "winner on iteration %d" iteration)
        "winner" (B.await promise)
    done

  let check_child_finalizer_catch_runs_after_release label caught released
      handler_observed_release = function
    | Exit.Ok _ ->
        Alcotest.(check bool) (label ^ " catch handler ran") true
          (Atomic.get caught);
        Alcotest.(check bool) (label ^ " released") true (Atomic.get released);
        Alcotest.(check bool) (label ^ " handler observed release") true
          (Atomic.get handler_observed_release)
    | Exit.Error cause ->
        Alcotest.failf "%s: expected catch recovery after release, got %a" label
          (Cause.pp Format.pp_print_string) cause

  let test_par_catch_runs_after_child_finalizer () =
    B.with_test_clock @@ fun ctx clock rt ->
    let acquired, acquired_u = B.create_promise () in
    let caught = Atomic.make false in
    let released = Atomic.make false in
    let handler_observed_release = Atomic.make false in
    let slow =
      Effect.acquire_release
        ~acquire:
          (Effect.sync (fun () ->
               B.resolve acquired_u ();
               ()))
        ~release:(fun () -> Effect.sync (fun () -> Atomic.set released true))
      |> Effect.bind (fun () -> Effect.delay (Duration.ms 1_000) Effect.unit)
    in
    let fail_after_acquire =
      B.await_effect acquired |> Effect.bind (fun () -> Effect.fail "body")
    in
    let eff =
      Effect.par fail_after_acquire slow
      |> Effect.catch (fun _ ->
             Atomic.set handler_observed_release (Atomic.get released);
             Atomic.set caught true;
             Effect.pure ((), ()))
    in
    let promise = B.fork_run ctx rt eff in
    wait_for_sleepers clock 1;
    check_child_finalizer_catch_runs_after_release "par" caught released
      handler_observed_release (B.await promise)

  let test_all_catch_runs_after_child_finalizer () =
    B.with_test_clock @@ fun ctx clock rt ->
    let acquired, acquired_u = B.create_promise () in
    let caught = Atomic.make false in
    let released = Atomic.make false in
    let handler_observed_release = Atomic.make false in
    let slow =
      Effect.acquire_release
        ~acquire:
          (Effect.sync (fun () ->
               B.resolve acquired_u ();
               ()))
        ~release:(fun () -> Effect.sync (fun () -> Atomic.set released true))
      |> Effect.bind (fun () -> Effect.delay (Duration.ms 1_000) Effect.unit)
    in
    let fail_after_acquire =
      B.await_effect acquired |> Effect.bind (fun () -> Effect.fail "body")
    in
    let eff =
      Effect.all [ fail_after_acquire; slow ]
      |> Effect.catch (fun _ ->
             Atomic.set handler_observed_release (Atomic.get released);
             Atomic.set caught true;
             Effect.pure [])
    in
    let promise = B.fork_run ctx rt eff in
    wait_for_sleepers clock 1;
    check_child_finalizer_catch_runs_after_release "all" caught released
      handler_observed_release (B.await promise)

  let test_for_each_par_catch_runs_after_child_finalizer () =
    B.with_test_clock @@ fun ctx clock rt ->
    let acquired, acquired_u = B.create_promise () in
    let caught = Atomic.make false in
    let released = Atomic.make false in
    let handler_observed_release = Atomic.make false in
    let worker = function
      | "slow" ->
          Effect.acquire_release
            ~acquire:
              (Effect.sync (fun () ->
                   B.resolve acquired_u ();
                   ()))
            ~release:(fun () -> Effect.sync (fun () -> Atomic.set released true))
          |> Effect.bind (fun () -> Effect.delay (Duration.ms 1_000) Effect.unit)
      | "body" ->
          B.await_effect acquired |> Effect.bind (fun () -> Effect.fail "body")
      | _ -> Effect.unit
    in
    let eff =
      Effect.for_each_par [ "body"; "slow" ] worker
      |> Effect.catch (fun _ ->
             Atomic.set handler_observed_release (Atomic.get released);
             Atomic.set caught true;
             Effect.pure [])
    in
    let promise = B.fork_run ctx rt eff in
    wait_for_sleepers clock 1;
    check_child_finalizer_catch_runs_after_release "for_each_par" caught
      released handler_observed_release (B.await promise)

  let tests =
    [
      ( "Effect",
        [
          Alcotest.test_case "Pure" `Quick test_pure;
          Alcotest.test_case "Map" `Quick test_map;
          Alcotest.test_case "collect_names" `Quick test_collect_names;
          Alcotest.test_case "map bind tap runtime" `Quick
            test_effect_map_bind_tap_runtime;
          Alcotest.test_case "tap observer runtime" `Quick
            test_effect_tap_observer_runtime;
          Alcotest.test_case "catch success and failure" `Quick
            test_effect_catch_success_and_failure;
          Alcotest.test_case "recover" `Quick test_effect_recover;
          Alcotest.test_case "ignore_errors" `Quick test_effect_ignore_errors;
          Alcotest.test_case "ignore" `Quick test_effect_ignore;
          Alcotest.test_case "result" `Quick test_effect_result;
          Alcotest.test_case "option" `Quick test_effect_option;
          Alcotest.test_case "exit" `Quick test_effect_exit;
          Alcotest.test_case "sleep now timed runtime clock" `Quick
            test_effect_sleep_now_and_timed_use_runtime_clock;
          Alcotest.test_case "timed preserves failures" `Quick
            test_effect_timed_preserves_failures;
          Alcotest.test_case "yield" `Quick test_effect_yield;
          Alcotest.test_case "catch handler failure uses outer key" `Quick
            test_effect_catch_handler_failure_uses_outer_key;
          Alcotest.test_case "from_result" `Quick test_effect_from_result;
          Alcotest.test_case "flatten_result" `Quick
            test_effect_flatten_result;
          Alcotest.test_case "exit to_result faithful subset" `Quick
            test_exit_to_result_only_converts_success_and_single_typed_failure;
          Alcotest.test_case "map_error maps full cause" `Quick
            test_effect_map_error_maps_full_cause;
          Alcotest.test_case "map_error preserves defects" `Quick
            test_effect_map_error_preserves_defects_in_cause_tree;
          Alcotest.test_case "map_error preserves interrupts" `Quick
            test_effect_map_error_preserves_interrupts_in_cause_tree;
          Alcotest.test_case "syntax operators" `Quick
            test_effect_syntax_operators;
          Alcotest.test_case "tap_error observes and rethrows" `Quick
            test_effect_tap_error_observes_and_rethrows;
          Alcotest.test_case "tap_error observer failure preserves typed failure"
            `Quick
            test_effect_tap_error_observer_failure_preserves_typed_failure;
          Alcotest.test_case "tap_error does not observe defects" `Quick
            test_effect_tap_error_does_not_observe_defects;
          Alcotest.test_case "die captures diagnostics" `Quick
            test_runtime_die_captures_diagnostics;
          Alcotest.test_case "finalizer die captures diagnostics" `Quick
            test_runtime_finalizer_die_captures_diagnostics;
          Alcotest.test_case "concurrent child die captures diagnostics" `Quick
            test_runtime_concurrent_child_die_captures_diagnostics;
          Alcotest.test_case "runtime exit fail die interrupt" `Quick
            test_runtime_exit_fail_die_interrupt;
          Alcotest.test_case "catch does not catch defect" `Quick
            test_effect_catch_does_not_catch_defect;
          Alcotest.test_case "catch does not catch interrupt" `Quick
            test_effect_catch_does_not_catch_interrupt;
          Alcotest.test_case "catch does not catch cancellation" `Quick
            test_effect_catch_does_not_catch_cancellation;
          Alcotest.test_case "map_error does not map cancellation" `Quick
            test_effect_map_error_does_not_map_cancellation;
          Alcotest.test_case "finally success and failure" `Quick
            test_effect_finally_success_and_failure;
          Alcotest.test_case "finally cleanup failure after success" `Quick
            test_effect_finally_cleanup_failure_after_success;
          Alcotest.test_case "finally suppresses cleanup failure" `Quick
            test_effect_finally_suppresses_cleanup_failure;
          Alcotest.test_case "finally runs after defect" `Quick
            test_effect_finally_runs_after_defect;
          Alcotest.test_case
            "finally suppresses cleanup failure after defect" `Quick
            test_effect_finally_suppresses_cleanup_failure_after_defect;
          Alcotest.test_case "finally runs on cancellation" `Quick
            test_effect_finally_runs_on_cancellation;
          Alcotest.test_case "on_exit observes success failure and defect"
            `Quick test_effect_on_exit_observes_success_failure_and_defect;
          Alcotest.test_case "on_exit observes interruption" `Quick
            test_effect_on_exit_observes_interruption;
          Alcotest.test_case "on_exit cleanup failure reporting" `Quick
            test_effect_on_exit_cleanup_failure_reporting;
          Alcotest.test_case "selective cleanup success noop" `Quick
            test_effect_selective_cleanup_success_noop;
          Alcotest.test_case
            "on_error observes typed defect and suppressed" `Quick
            test_effect_on_error_observes_typed_defect_and_suppressed;
          Alcotest.test_case "on_error skips interruption" `Quick
            test_effect_on_error_skips_interruption;
          Alcotest.test_case "on_interrupt observes interruption" `Quick
            test_effect_on_interrupt_observes_interruption;
          Alcotest.test_case "selective cleanup failure reporting" `Quick
            test_effect_selective_cleanup_failure_reporting;
          Alcotest.test_case
            "acquire_use_release_exit observes success failure and defect"
            `Quick
            test_acquire_use_release_exit_observes_success_failure_and_defect;
          Alcotest.test_case "acquire_use_release_exit observes interruption"
            `Quick test_acquire_use_release_exit_observes_interruption;
          Alcotest.test_case "acquire_use_release_exit release failure reporting"
            `Quick test_acquire_use_release_exit_release_failure_reporting;
          Alcotest.test_case "with_resource_exit alias success" `Quick
            test_with_resource_exit_alias_success;
          Alcotest.test_case "catch preserves suppressed finalizer failure"
            `Quick test_effect_catch_preserves_suppressed_finalizer_failure;
          Alcotest.test_case "catch preserves finalizer defect" `Quick
            test_effect_catch_preserves_suppressed_finalizer_defect;
          Alcotest.test_case "catch strips typed primary before finalizer"
            `Quick test_effect_catch_strips_typed_primary_before_finalizer;
          Alcotest.test_case "catch composite typed failure no old payloads"
            `Quick test_effect_catch_composite_typed_failure_no_old_payloads;
          Alcotest.test_case
            "catch concurrent typed failure runs one handler" `Quick
            test_effect_catch_invokes_one_handler_for_concurrent_typed_failure;
          Alcotest.test_case "catch preserves concurrent defect" `Quick
            test_effect_catch_preserves_concurrent_defect;
          Alcotest.test_case "empty cause aggregations reject" `Quick
            test_cause_empty_aggregations_reject;
          Alcotest.test_case "diagnostic cause equality" `Quick
            test_cause_diagnostic_equal_compares_die_payloads;
          Alcotest.test_case "runtime user Exit is defect" `Quick
            test_runtime_user_exit_is_defect;
          Alcotest.test_case "portable cause materializes diagnostics" `Quick
            test_cause_to_portable_materializes_diagnostics;
          Alcotest.test_case "explicit dependency passing" `Quick
            test_explicit_dependency_passing;
          Alcotest.test_case "par returns pair" `Quick
            test_par_returns_both_successes;
          Alcotest.test_case "par keeps heterogeneous successes private"
            `Quick test_par_keeps_heterogeneous_successes_private;
          Alcotest.test_case "all collects in input order" `Quick
            test_all_collects_in_input_order;
          Alcotest.test_case "all empty returns empty list" `Quick
            test_all_empty_returns_empty_list;
          Alcotest.test_case "all fail-fast" `Quick test_all_fail_fast;
          Alcotest.test_case "all_settled collects outcomes" `Quick
            test_all_settled_collects_successes_and_failures;
          Alcotest.test_case "all_settled empty" `Quick
            test_all_settled_empty;
          Alcotest.test_case "for_each_par success" `Quick
            test_for_each_par_success;
          Alcotest.test_case "for_each_par one fails" `Quick
            test_for_each_par_one_fails;
          Alcotest.test_case "for_each_par_bounded max one is sequential"
            `Quick test_for_each_par_bounded_max_one_is_sequential;
          Alcotest.test_case "for_each_par_bounded rejects nonpositive max"
            `Quick test_for_each_par_bounded_rejects_nonpositive_max;
          Alcotest.test_case "for_each_par mapper defect is runtime die"
            `Quick test_for_each_par_mapper_defect_is_runtime_die;
          Alcotest.test_case
            "for_each_par_bounded mapper defect is runtime die" `Quick
            test_for_each_par_bounded_mapper_defect_is_runtime_die;
          Alcotest.test_case "par fail-fast cancels sibling" `Quick
            test_par_fail_fast_cancels_sibling;
          Alcotest.test_case "par simultaneous failures baseline" `Quick
            test_par_simultaneous_failures_records_concurrent_baseline;
          Alcotest.test_case "par finalizer cancellation baseline" `Quick
            test_par_finalizer_failure_during_sibling_cancellation;
          Alcotest.test_case "par catch recovers after sibling cancel" `Quick
            test_par_catch_recovers_typed_failure_after_sibling_cancel;
          Alcotest.test_case "all preserves delayed input order" `Quick
            test_all_preserves_input_order_with_out_of_order_completion;
          Alcotest.test_case "all catch recovers after sibling cancel" `Quick
            test_all_catch_recovers_typed_failure_after_sibling_cancel;
          Alcotest.test_case "all finalizer cancellation baseline" `Quick
            test_all_finalizer_failure_during_sibling_cancellation_baseline;
          Alcotest.test_case "all_settled preserves delayed input order" `Quick
            test_all_settled_preserves_input_order_with_out_of_order_completion;
          Alcotest.test_case "all_settled runs all children" `Quick
            test_all_settled_runs_all_children;
          Alcotest.test_case "all_settled timeout scoped resource typed" `Quick
            test_all_settled_timeout_scoped_resource_is_typed;
          Alcotest.test_case "for_each_par preserves delayed input order" `Quick
            test_for_each_par_preserves_input_order_with_out_of_order_completion;
          Alcotest.test_case "for_each_par_bounded caps concurrency" `Quick
            test_for_each_par_bounded_caps_concurrency;
          Alcotest.test_case "for_each_par_bounded fail-fast" `Quick
            test_for_each_par_bounded_fail_fast;
          Alcotest.test_case "for_each_par simultaneous failures baseline" `Quick
            test_for_each_par_simultaneous_failures_baseline;
          Alcotest.test_case "for_each_par finalizer cancellation baseline"
            `Quick test_for_each_par_finalizer_failure_during_sibling_cancellation;
          Alcotest.test_case "race ignores early failure until success" `Quick
            test_effect_race_ignores_early_failure_until_success;
          Alcotest.test_case "race cancels losers after first success" `Quick
            test_effect_race_cancels_losers_after_first_success;
          Alcotest.test_case
            "race simultaneous success/failure returns winner" `Quick
            test_effect_race_simultaneous_success_and_failure_returns_winner;
          Alcotest.test_case "race all failures returns concurrent causes" `Quick
            test_effect_race_all_failures_returns_concurrent_causes;
          Alcotest.test_case "race releases scoped loser resource" `Quick
            test_effect_race_releases_scoped_loser_resource;
          Alcotest.test_case
            "race reports loser finalizer failure after winner" `Quick
            test_effect_race_reports_loser_finalizer_failure_after_winner;
          Alcotest.test_case "race timeout during cleanup keeps winner" `Quick
            test_effect_race_timeout_during_loser_cleanup_keeps_winner;
          Alcotest.test_case "par catch waits for child finalizer" `Quick
            test_par_catch_runs_after_child_finalizer;
          Alcotest.test_case "all catch waits for child finalizer" `Quick
            test_all_catch_runs_after_child_finalizer;
          Alcotest.test_case
            "for_each_par catch waits for child finalizer" `Quick
            test_for_each_par_catch_runs_after_child_finalizer;
          Alcotest.test_case "par nested race failures baseline" `Quick
            test_par_nested_race_all_failures_baseline;
        ] );
    ]
end
