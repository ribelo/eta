module Cause = Eta.Cause
module Cleanup = Eta_signal_cleanup
module Effect = Eta.Effect

type test_error = [ `Primary ]

let pp_hidden ppf _ = Format.pp_print_string ppf "<cleanup-error>"

let run runtime eff = Eta_eio.Runtime.run runtime eff

let run_ok runtime eff =
  match run runtime eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop index =
    if index + needle_len > haystack_len then false
    else if String.sub haystack index needle_len = needle then true
    else loop (index + 1)
  in
  needle_len = 0 || loop 0

let cause_has_die_message expected cause =
  Cause.defects cause
  |> List.exists (fun die ->
         contains_substring (Printexc.to_string die.Cause.exn) expected)

let rec finalizer_has_die_message expected = function
  | Cause.Finalizer.Die die ->
      contains_substring (Printexc.to_string die.Cause.exn) expected
  | Cause.Finalizer.Sequential causes | Cause.Finalizer.Concurrent causes ->
      List.exists (finalizer_has_die_message expected) causes
  | Cause.Finalizer.Finalizer cause -> finalizer_has_die_message expected cause
  | Cause.Finalizer.Suppressed { primary; finalizer } ->
      finalizer_has_die_message expected primary
      || finalizer_has_die_message expected finalizer
  | Cause.Finalizer.Fail _ | Cause.Finalizer.Interrupt _ -> false

let expect_cleanup_defect label expected = function
  | Eta.Exit.Error cause when cause_has_die_message expected cause -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s: expected cleanup defect %S, got %a" label expected
        (Cause.pp pp_hidden) cause
  | Eta.Exit.Ok _ -> Alcotest.failf "%s: expected cleanup defect, got Ok" label

let expect_suppressed_primary_with_finalizer label expected = function
  | Eta.Exit.Error
      (Cause.Suppressed
        { primary = Cause.Fail `Primary; finalizer })
    when finalizer_has_die_message expected finalizer -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf
        "%s: expected primary failure with suppressed cleanup defect %S, got %a"
        label expected (Cause.pp pp_hidden) cause
  | Eta.Exit.Ok _ ->
      Alcotest.failf "%s: expected primary failure, got Ok" label

let test_run_hooks_continues_after_failure () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let calls = ref [] in
  let record value () = calls := value :: !calls in
  let fail message () = failwith message in
  let hooks =
    [
      record 1;
      fail "first cleanup failure";
      record 2;
      fail "second cleanup failure";
      record 3;
    ]
  in
  let exit = run runtime (Cleanup.run_hooks hooks) in
  expect_cleanup_defect "run_hooks" "first cleanup failure"
    exit;
  Alcotest.(check bool)
    "second cleanup failure preserved" true
    (match exit with
    | Eta.Exit.Error cause -> cause_has_die_message "second cleanup failure" cause
    | Eta.Exit.Ok _ -> false);
  Alcotest.(check (list int)) "all non-failing hooks ran" [ 1; 2; 3 ]
    (List.rev !calls)

let test_run_pending_as_finalizers_clears_ref () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let calls = ref 0 in
  let hooks_ref = ref [ (fun () -> incr calls) ] in
  run_ok runtime (Cleanup.run_pending_as_finalizers hooks_ref);
  Alcotest.(check int) "hook ran" 1 !calls;
  Alcotest.(check bool) "hooks cleared" false (Cleanup.pending hooks_ref);
  run_ok runtime (Cleanup.run_pending_as_finalizers hooks_ref);
  Alcotest.(check int) "cleared hooks do not rerun" 1 !calls

let test_failed_pending_finalizer_clears_ref () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let hooks_ref =
    ref [ (fun () -> failwith "pending cleanup finalizer failure") ]
  in
  expect_cleanup_defect "pending finalizer"
    "pending cleanup finalizer failure"
    (run runtime (Cleanup.run_pending_as_finalizers hooks_ref));
  Alcotest.(check bool) "hooks cleared after failure" false
    (Cleanup.pending hooks_ref)

let test_fail_with_pending_preserves_primary_failure () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let hooks_ref = ref [ (fun () -> failwith "suppressed cleanup failure") ] in
  let eff : (unit, test_error) Effect.t =
    Cleanup.fail_with_pending hooks_ref (Effect.fail `Primary)
  in
  expect_suppressed_primary_with_finalizer "fail_with_pending"
    "suppressed cleanup failure" (run runtime eff);
  Alcotest.(check bool) "hooks cleared" false (Cleanup.pending hooks_ref)

let () =
  Alcotest.run "eta_signal_cleanup"
    [
      ( "cleanup",
        [
          Alcotest.test_case "run hooks continues after failure" `Quick
            test_run_hooks_continues_after_failure;
          Alcotest.test_case "pending finalizers clear ref" `Quick
            test_run_pending_as_finalizers_clears_ref;
          Alcotest.test_case "failed pending finalizer clears ref" `Quick
            test_failed_pending_finalizer_clears_ref;
          Alcotest.test_case "pending finalizer preserves primary failure" `Quick
            test_fail_with_pending_preserves_primary_failure;
        ] );
    ]
