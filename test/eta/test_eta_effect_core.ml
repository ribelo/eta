open Eta
open Eta_test
open Test_eta_support

module Counting_host_eio = struct
  let switch_runs = Atomic.make 0
  let active_switch = Atomic.make None

  module Eio_ops = struct
    module Time = struct
      let now = Eio.Time.now
      let sleep = Eio.Time.sleep
    end

    module Net = struct
      let getaddrinfo_stream = Eio.Net.getaddrinfo_stream
      let connect = Eio.Net.connect
    end

    module Flow = struct
      let single_read = Eio.Flow.single_read
      let write = Eio.Flow.write
    end

    module Switch = struct
      let run ?name f =
        ignore name;
        Atomic.incr switch_runs;
        match Atomic.get active_switch with
        | Some sw -> f sw
        | None -> invalid_arg "Counting_host_eio.Switch.run: no active switch"

      let fail ?bt sw exn = Eio.Switch.fail ?bt sw exn
    end

    module Fiber = struct
      let get _ = None
      let with_binding _ _ f = f ()
      let first ?combine left right = Eio.Fiber.first ?combine left right
      let await_cancel = Eio.Fiber.await_cancel
      let fork ~sw f = Eio.Fiber.fork ~sw f
      let fork_daemon ~sw f = Eio.Fiber.fork_daemon ~sw f
      let yield = Eio.Fiber.yield
    end

    module Cancel = struct
      let sub = Eio.Cancel.sub
      let cancel = Eio.Cancel.cancel
    end
  end

  let with_host sw f =
    Atomic.set switch_runs 0;
    Atomic.set active_switch (Some sw);
    Fun.protect
      ~finally:(fun () -> Atomic.set active_switch None)
      (fun () -> f (Host_eio.make ~unix:(module Eio_unix) ~eio:(module Eio_ops) ()))
end

let run_in_system_thread f =
  let result = ref None in
  let thread =
    Thread.create
      (fun () ->
        result :=
          Some
            (try Ok (f ())
             with exn -> Error (exn, Printexc.get_raw_backtrace ())))
      ()
  in
  Thread.join thread;
  match !result with
  | Some (Ok value) -> value
  | Some (Error (exn, backtrace)) ->
      Printexc.raise_with_backtrace exn backtrace
  | None -> Alcotest.fail "system thread did not return a result"

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

let test_effect_from_result () =
  with_runtime @@ fun rt ->
  Alcotest.(check int) "ok" 7 (run_ok rt (Effect.from_result (Ok 7)));
  Expect.expect_typed_failure_eq Alcotest.string
    (Runtime.run rt (Effect.from_result (Error "bad")))
    "bad"

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
  with_runtime @@ fun rt ->
  let eff =
    Effect.scoped
      (Effect.acquire_release ~acquire:Effect.unit
         ~release:(fun () ->
           Effect.fail `Release)
      |> Effect.bind (fun () -> Effect.fail `Body))
    |> Effect.map_error (function
         | `Body -> "body"
         | `Release -> "release")
  in
  match Runtime.run rt eff with
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
  with_runtime @@ fun rt ->
  let eff =
    Effect.scoped
      (Effect.acquire_release ~acquire:Effect.unit
         ~release:(fun () ->
           Effect.sync (fun () -> failwith "release defect"))
      |> Effect.bind (fun () -> Effect.fail `Body))
    |> Effect.map_error (function `Body -> "body")
  in
  match Runtime.run rt eff with
  | Exit.Error
      (Cause.Suppressed
        { primary = Cause.Fail "body"; finalizer = Cause.Finalizer.Die _ }) ->
      ()
  | Exit.Error cause ->
      Alcotest.failf "expected mapped typed failure with preserved defect, got %a"
        (Cause.pp Format.pp_print_string) cause
  | Exit.Ok _ -> Alcotest.fail "expected suppressed defect"

let test_effect_map_error_preserves_interrupts_in_cause_tree () =
  with_runtime @@ fun rt ->
  let eff =
    Effect.scoped
      (Effect.acquire_release ~acquire:Effect.unit
         ~release:(fun () ->
           Effect.sync (fun () ->
               raise (Eio.Cancel.Cancelled (Failure "release interrupt"))))
      |> Effect.bind (fun () -> Effect.fail `Body))
    |> Effect.map_error (function `Body -> "body")
  in
  match Runtime.run rt eff with
  | Exit.Error
      (Cause.Suppressed
        { primary = Cause.Fail "body"; finalizer = Cause.Finalizer.Interrupt _ }) ->
      ()
  | Exit.Error cause ->
      Alcotest.failf
        "expected mapped typed failure with preserved interrupt, got %a"
        (Cause.pp Format.pp_print_string) cause
  | Exit.Ok _ -> Alcotest.fail "expected suppressed interrupt"

let test_effect_scoped_creates_switch_in_fiberless_host_run () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  Counting_host_eio.with_host sw @@ fun host ->
  Runtime.with_host_eio host ~sw ~clock:(Eio.Stdenv.clock stdenv)
  @@ fun rt ->
  let before = Atomic.get Counting_host_eio.switch_runs in
  let exit =
    run_in_system_thread (fun () ->
        Runtime.run rt (Effect.scoped Effect.unit))
  in
  check_exit_ok Alcotest.unit "scoped result" () exit;
  Alcotest.(check int)
    "fiberless scoped host switch runs" 1
    (Atomic.get Counting_host_eio.switch_runs - before)

let test_effect_syntax_operators () =
  with_runtime @@ fun rt ->
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
  with_runtime @@ fun rt ->
  let observed = ref false in
  let eff =
    Effect.sync (fun () -> failwith "body defect")
    |> Effect.tap_error (fun (_ : string) -> observed := true)
  in
  (match Runtime.run rt eff with
  | Exit.Error (Cause.Die _) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected defect, got %a"
        (Cause.pp Format.pp_print_string) cause
  | Exit.Ok _ -> Alcotest.fail "expected defect");
  Alcotest.(check bool) "observer not called" false !observed

let test_effect_finally_success_and_failure () =
  with_runtime @@ fun rt ->
  let finalized = ref 0 in
  let cleanup = Effect.sync (fun () -> incr finalized) in
  let success = Effect.pure 42 |> Effect.finally cleanup in
  let failure = Effect.fail "body" |> Effect.finally cleanup in
  Alcotest.(check int) "success value" 42 (run_ok rt success);
  Expect.expect_typed_failure_eq Alcotest.string (Runtime.run rt failure) "body";
  Alcotest.(check int) "cleanup count" 2 !finalized

let test_effect_finally_cleanup_failure_after_success () =
  with_runtime @@ fun rt ->
  let eff =
    Effect.pure 42
    |> Effect.finally (Effect.fail "cleanup")
    |> Effect.catch (fun (_ : string) -> Effect.pure 0)
  in
  match Runtime.run rt eff with
  | Exit.Error (Cause.Finalizer (Cause.Finalizer.Fail "<typed failure>")) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected finalizer cleanup failure, got %a"
        (Cause.pp Format.pp_print_string) cause
  | Exit.Ok _ -> Alcotest.fail "catch erased cleanup failure after success"

let test_effect_finally_suppresses_cleanup_failure () =
  with_runtime @@ fun rt ->
  let eff =
    Effect.fail "body"
    |> Effect.finally (Effect.fail "cleanup")
  in
  match Runtime.run rt eff with
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
  with_runtime @@ fun rt ->
  let cleaned = ref false in
  let eff =
    Effect.sync (fun () -> failwith "body defect")
    |> Effect.finally (Effect.sync (fun () -> cleaned := true))
  in
  (match Runtime.run rt eff with
  | Exit.Error (Cause.Die _) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected body defect, got %a"
        (Cause.pp Format.pp_print_string) cause
  | Exit.Ok _ -> Alcotest.fail "expected body defect");
  Alcotest.(check bool) "cleaned" true !cleaned

let test_effect_finally_suppresses_cleanup_failure_after_defect () =
  with_runtime @@ fun rt ->
  let eff =
    Effect.sync (fun () -> failwith "body defect")
    |> Effect.finally (Effect.fail "cleanup")
  in
  match Runtime.run rt eff with
  | Exit.Error
      (Cause.Suppressed
        { primary = Cause.Die _; finalizer = Cause.Finalizer.Fail "<typed failure>" }) ->
      ()
  | Exit.Error cause ->
      Alcotest.failf "expected suppressed cleanup failure after defect, got %a"
        (Cause.pp Format.pp_print_string) cause
  | Exit.Ok _ -> Alcotest.fail "expected suppressed cleanup failure after defect"

let test_effect_finally_runs_on_cancellation () =
  with_test_clock @@ fun sw clock rt ->
  let finalized = ref false in
  let slow =
    Effect.delay (Duration.ms 1_000) (Effect.pure "slow")
    |> Effect.finally (Effect.sync (fun () -> finalized := true))
  in
  let fast =
    Effect.sync (fun () -> wait_for_sleepers clock 1)
    |> Effect.map (fun () -> "fast")
  in
  let promise = fork_run sw rt (Effect.race [ slow; fast ]) in
  check_exit_ok Alcotest.string "fast wins" "fast" (Eio.Promise.await promise);
  Alcotest.(check bool) "cleanup ran" true !finalized

let test_effect_catch_preserves_suppressed_finalizer_failure () =
  with_runtime @@ fun rt ->
  let eff =
    Effect.fail `Body
    |> Effect.finally
         (Effect.fail `Cleanup)
    |> Effect.catch (function `Body -> Effect.pure `Caught)
  in
  match Runtime.run rt eff with
  | Exit.Error (Cause.Finalizer (Cause.Finalizer.Fail "<typed failure>")) ->
      ()
  | Exit.Ok `Caught ->
      Alcotest.fail "catch erased the finalizer typed failure"
  | Exit.Error cause ->
      Alcotest.failf "expected finalizer typed failure to remain, got %a"
        (Cause.pp (fun fmt -> function
          | `Body -> Format.pp_print_string fmt "body"
          | `Cleanup -> Format.pp_print_string fmt "cleanup"))
        cause

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

let test_runtime_run_exn_preserves_typed_failure_diagnostics () =
  (* P2: run_exn discards typed failure diagnostics.
     When a typed Fail cause occurs, run_exn should include the error
     information in the exception message. Currently it just says
     "Eta.Runtime.run_exn" with no context about what failed. *)
  with_runtime @@ fun rt ->
  let eff = Effect.fail "detailed error: connection refused on port 8080" in
  match Runtime.run_exn rt eff with
  | _ -> Alcotest.fail "expected exception from typed failure"
  | exception (Failure msg) ->
      (* The exception message should contain the typed error information,
         not just a generic "Eta.Runtime.run_exn" string. *)
      let has_detail =
        String.length msg > 20 (* more than just "Eta.Runtime.run_exn" *)
        && (let needle = "connection refused" in
            let nlen = String.length needle in
            let slen = String.length msg in
            let rec loop i =
              if i + nlen > slen then false
              else if String.sub msg i nlen = needle then true
              else loop (i + 1)
            in
            loop 0)
      in
      Alcotest.(check bool)
        (Printf.sprintf
           "run_exn should preserve typed failure info in message \
            (got: %S)" msg)
        true has_detail
  | exception _ ->
      Alcotest.fail "expected Failure exception from run_exn"

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
        {
          primary = Cause.Die primary;
          finalizer = Cause.Finalizer.Die finalizer;
        }) ->
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

let test_effect_catch_preserves_suppressed_finalizer_defect () =
  with_runtime @@ fun rt ->
  let defect = Failure "cleanup defect" in
  let eff =
    Effect.fail "body"
    |> Effect.finally (Effect.sync (fun () -> raise defect))
    |> Effect.catch (fun (_ : string) -> Effect.pure "caught")
  in
  match Runtime.run rt eff with
  | Exit.Error (Cause.Finalizer (Cause.Finalizer.Die { exn; _ }))
    when exn == defect ->
      ()
  | Exit.Error cause ->
      Alcotest.failf "expected finalizer defect, got %a"
        (Cause.pp Format.pp_print_string) cause
  | Exit.Ok value -> Alcotest.failf "catch swallowed defect as %S" value

let test_effect_catch_preserves_concurrent_defect () =
  with_test_clock @@ fun sw _clock rt ->
  let defect = Failure "concurrent defect" in
  let go, release = Eio.Promise.create () in
  let ready = Eio.Stream.create 2 in
  let wait name =
    Effect.sync (fun () ->
        Eio.Stream.add ready name;
        Eio.Promise.await go)
  in
  let typed = wait "typed" |> Effect.bind (fun () -> Effect.fail "typed") in
  let die =
    wait "die" |> Effect.bind (fun () ->
      Effect.sync (fun () -> raise defect))
  in
  let eff =
    Effect.all [ typed; die ]
    |> Effect.catch (fun (_ : string) -> Effect.pure [ () ])
  in
  let promise = fork_run sw rt eff in
  ignore (Eio.Stream.take ready : string);
  ignore (Eio.Stream.take ready : string);
  Eio.Promise.resolve release ();
  match Eio.Promise.await promise with
  | Exit.Error (Cause.Die { exn; _ }) when exn == defect -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected concurrent defect, got %a"
        (Cause.pp Format.pp_print_string) cause
  | Exit.Ok _ -> Alcotest.fail "catch swallowed concurrent defect"

let test_effect_catch_preserves_concurrent_interrupt () =
  with_test_clock @@ fun sw _clock rt ->
  let go, release = Eio.Promise.create () in
  let ready = Eio.Stream.create 2 in
  let wait name =
    Effect.sync (fun () ->
        Eio.Stream.add ready name;
        Eio.Promise.await go)
  in
  let typed = wait "typed" |> Effect.bind (fun () -> Effect.fail "typed") in
  let interrupt =
    wait "interrupt"
    |> Effect.bind (fun () ->
           Effect.sync (fun () ->
               raise (Eio.Cancel.Cancelled (Failure "cancel"))))
  in
  let eff =
    Effect.all [ typed; interrupt ]
    |> Effect.catch (fun (_ : string) -> Effect.pure [ () ])
  in
  let promise = fork_run sw rt eff in
  ignore (Eio.Stream.take ready : string);
  ignore (Eio.Stream.take ready : string);
  Eio.Promise.resolve release ();
  match Eio.Promise.await promise with
  | Exit.Error (Cause.Interrupt None) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected concurrent interrupt, got %a"
        (Cause.pp Format.pp_print_string) cause
  | Exit.Ok _ -> Alcotest.fail "catch swallowed concurrent interrupt"

(* P0: Effect.catch is unsound for typed failures nested inside cause trees.
   When catch changes the error type from 'err1 to 'err2, any Suppressed or
   Concurrent cause that contains nested Fail old_err values passes through
   via Obj.magic. The nested Fail payloads are cast to the new error type
   without being transformed. This is a type-safety violation.

   map_error correctly recurses into cause trees; catch does not.
   This test demonstrates the unsoundness by checking that nested Fail
   values inside Suppressed causes have the correct type after catch. *)

let test_effect_catch_unsound_suppressed_typed_failure () =
  with_runtime @@ fun rt ->
  (* Create an effect that:
     1. Has error type [`Old_err]
     2. Body fails with `Old_err
     3. Finalizer also fails with `Old_err
     4. This produces Suppressed { primary = Fail `Old_err; finalizer = Fail `Old_err }
     5. catch handles `Old_err but the Suppressed cause bypasses the handler
     6. After catch, the error type is [`New_err] but the cause still
        contains `Old_err payloads — a type-level unsoundness *)
  let eff =
    Effect.fail `Old_err
    |> Effect.finally (Effect.fail `Old_cleanup)
    |> Effect.catch (function
         | `Old_err -> Effect.pure "handled"
         | `Old_cleanup -> Effect.pure "handled cleanup")
  in
  match Runtime.run rt eff with
  | Exit.Ok "handled" ->
      (* If catch somehow caught it, fine *)
      ()
  | Exit.Ok _ -> Alcotest.fail "unexpected Ok value"
  | Exit.Error cause ->
      (* The cause passed through catch. It's now typed as the NEW error type
         (whatever catch's return error type is), but still contains the OLD
         typed failure payloads. Verify the Fail values are what they should be
         if the types were respected.

         With Obj.magic unsoundness, the values are physically `Old_err and
         `Old_cleanup but the type says they should be the new error type.
         We can detect this by checking the cause structure: if we see
         Fail values that are physically polymorphic variants from the OLD
         type, that proves the unsoundness.

         The correct behavior (like map_error) would either:
         - Recursively transform nested Fails through the handler
         - Or return the cause as-is but with the ORIGINAL type preserved *)
      let has_old_err_in_cause =
        match cause with
        | Cause.Suppressed
            { primary = Cause.Fail _; finalizer = Cause.Finalizer.Fail _ } ->
            (* These Fail values are typed as the NEW error type but physically
               contain OLD error values. The mere fact that we got here with
               Suppressed { Fail; Fail } after catch changed the type proves
               the unsoundness — these payloads were never transformed. *)
            true
        | _ -> false
      in
      Alcotest.(check bool)
        "catch should not pass through Suppressed with un-transformed Fail \
         payloads (type-level unsoundness via Obj.magic)"
        false has_old_err_in_cause

let test_effect_catch_unsound_concurrent_typed_failure () =
  with_runtime @@ fun rt ->
  (* Same unsoundness but with Concurrent causes from par/all.
     If two fibers fail with typed errors and catch handles that error type,
     Concurrent [Fail old_err; Fail old_err] passes through catch via
     Obj.magic without transforming the nested Fail payloads. *)
  let eff =
    Effect.all
      [ Effect.fail `Fiber_a_err;
        Effect.fail `Fiber_b_err ]
    |> Effect.catch (function
         | `Fiber_a_err -> Effect.pure [ () ]
         | `Fiber_b_err -> Effect.pure [ () ])
  in
  match Runtime.run rt eff with
  | Exit.Ok _ -> () (* If catch somehow caught it, fine *)
  | Exit.Error cause ->
      let has_nested_fail =
        match cause with
        | Cause.Concurrent causes ->
            List.exists (function Cause.Fail _ -> true | _ -> false) causes
        | Cause.Fail _ -> true (* Single fail that was magic'd *)
        | _ -> false
      in
      Alcotest.(check bool)
        "catch should not pass through Concurrent with un-transformed Fail \
         payloads (type-level unsoundness via Obj.magic)"
        false has_nested_fail
