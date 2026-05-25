open Eta
open Test
open Test_eta_support

let test_pure () =
  with_runtime @@ fun rt ->
  Alcotest.(check int) "pure" 42 (run_ok rt (Effect.pure 42))

let test_map () =
  with_runtime @@ fun rt ->
  let e = Effect.pure 1 |> Effect.map (fun n -> n + 1) in
  Alcotest.(check int) "map" 2 (run_ok rt e)

let test_collect_names () =
  let e =
    Effect.concat
      [
        Effect.named "leaf-a" (Effect.sync (fun () -> ())) |> Effect.map (fun _ -> ());
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
  with_runtime @@ fun rt ->
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

let test_effect_catch_success_and_failure () =
  with_runtime @@ fun rt ->
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

let test_effect_catch_handler_failure_uses_outer_key () =
  with_runtime @@ fun rt ->
  let eff =
    Effect.fail `Inner
    |> Effect.catch (fun (`Inner : [ `Inner ]) -> Effect.fail `Outer)
  in
  Expect.expect_typed_failure_eq
    (Alcotest.testable
       (fun fmt -> function
         | `Inner -> Format.pp_print_string fmt "inner"
         | `Outer -> Format.pp_print_string fmt "outer")
       ( = ))
    (Runtime.run rt eff) `Outer

let test_effect_tap_error_observes_and_rethrows () =
  with_runtime @@ fun rt ->
  let observed = ref false in
  let eff =
    Effect.fail `Boom
    |> Effect.tap_error (fun (`Boom : [ `Boom ]) -> observed := true)
    |> Effect.catch (fun (`Boom : [ `Boom ]) -> Effect.pure "recovered")
  in
  Alcotest.(check string) "recovered" "recovered" (run_ok rt eff);
  Alcotest.(check bool) "observed" true !observed

let test_effect_tap_error_observer_failure_preserves_typed_failure () =
  with_runtime @@ fun rt ->
  let eff =
    Effect.fail `My_error
    |> Effect.tap_error (fun (`My_error : [ `My_error ]) ->
           failwith "observer crash")
  in
  match Runtime.run rt eff with
  | Exit.Error
      (Cause.Suppressed
        {
          primary = Cause.Fail `My_error;
          finalizer = Cause.Die { exn; _ };
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

let test_runtime_exit_fail_die_interrupt () =
  with_runtime @@ fun rt ->
  let die = Failure "boom" in
  let fail_exit = Runtime.run rt (Effect.fail "bad") in
  let die_exit = Runtime.run rt (Effect.named "die" (Effect.sync (fun () -> raise die))) in
  let interrupt_exit =
    Runtime.run rt
      (Effect.named "interrupt" (Effect.sync (fun () ->
           raise (Eio.Cancel.Cancelled (Failure "cancel")))))
  in
  Expect.expect_typed_failure_eq Alcotest.string fail_exit "bad";
  Expect.expect_die die_exit (fun actual -> actual.exn == die);
  Expect.expect_interrupt interrupt_exit

let test_runtime_die_captures_diagnostics () =
  with_sampled_traced_runtime Sampler.always_off @@ fun rt _tracer ->
  let exn = Failure "diagnostic boom" in
  let eff =
    Effect.named "die.leaf" (Effect.sync (fun () -> raise exn))
    |> Effect.annotate ~key:"request.id" ~value:"r-1"
    |> Effect.fn __POS__ "diagnostic.fn"
  in
  match Runtime.run rt eff with
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

let test_cause_to_portable_materializes_diagnostics () =
  let backtrace = Printexc.get_callstack 4 in
  let raw =
    Cause.suppressed ~primary:(Cause.fail "typed")
      ~finalizer:
        (Cause.die_with_diagnostics ~backtrace ~span_name:"release"
           ~annotations:[ ("phase", "release") ] (Failure "boom"))
  in
  match Cause.to_portable Fun.id raw with
  | Cause.Portable.Suppressed
      {
        primary = Cause.Portable.Fail "typed";
        finalizer =
          Cause.Portable.Die
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

let test_runtime_die_capture_backtrace_can_be_disabled () =
  with_runtime_capture_backtrace false @@ fun rt ->
  match
    Runtime.run rt (Effect.named "die.no-backtrace" (Effect.sync (fun () -> failwith "boom")))
  with
  | Exit.Error (Cause.Die die) ->
      Alcotest.(check (option string)) "no backtrace" None
        (Option.map Printexc.raw_backtrace_to_string die.backtrace)
  | _ -> Alcotest.fail "expected Die"

let test_runtime_run_exn_uses_captured_backtrace () =
  with_runtime @@ fun rt ->
  let exn = Failure "run_exn defect" in
  match Runtime.run_exn rt (Effect.named "die.run_exn" (Effect.sync (fun () -> raise exn))) with
  | _ -> Alcotest.fail "expected exception"
  | exception actual ->
      Alcotest.(check bool) "same exception" true (actual == exn);
      let backtrace = Printexc.raw_backtrace_to_string (Printexc.get_raw_backtrace ()) in
      Alcotest.(check bool) "backtrace not empty" true (String.length backtrace > 0)

let test_runtime_concurrent_child_die_captures_diagnostics () =
  with_runtime @@ fun rt ->
  let left_ready, left_resolver = Eio.Promise.create () in
  let right_ready, right_resolver = Eio.Promise.create () in
  let child name own_ready other_ready =
    Effect.named name (Effect.sync (fun () ->
        Eio.Promise.resolve own_ready ();
        Eio.Promise.await other_ready;
        raise (Failure name)))
    |> Effect.annotate ~key:"branch" ~value:name
    |> Effect.named (name ^ ".span")
  in
  let eff =
    Effect.par
      (child "left" left_resolver right_ready)
      (child "right" right_resolver left_ready)
  in
  match Runtime.run rt eff with
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

let test_runtime_finalizer_die_captures_diagnostics () =
  with_runtime @@ fun rt ->
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
  match Runtime.run rt eff with
  | Exit.Error
      (Cause.Suppressed
        { primary = Cause.Die primary; finalizer = Cause.Die finalizer }) ->
      Alcotest.(check bool) "primary exn" true (primary.exn == body_exn);
      Alcotest.(check (option string)) "primary span" (Some "body.leaf")
        primary.span_name;
      Alcotest.(check bool) "finalizer exn" true (finalizer.exn == release_exn);
      Alcotest.(check (option string)) "finalizer span" (Some "release.leaf")
        finalizer.span_name;
      Alcotest.(check (option string)) "finalizer annotation" (Some "release")
        (List.assoc_opt "phase" finalizer.annotations)
  | Exit.Error cause ->
      Alcotest.failf "unexpected cause: %a" (Cause.pp Format.pp_print_string)
        cause
  | Exit.Ok _ -> Alcotest.fail "expected finalizer Die"

let test_effect_catch_does_not_catch_interrupt () =
  with_runtime @@ fun rt ->
  let eff =
    Effect.named "interrupt" (Effect.sync (fun () ->
        raise (Eio.Cancel.Cancelled (Failure "cancel"))))
    |> Effect.catch (fun (_ : string) -> Effect.pure "caught")
  in
  match Runtime.run rt eff with
  | Exit.Error (Cause.Interrupt None) -> ()
  | _ -> Alcotest.fail "expected Interrupt"
