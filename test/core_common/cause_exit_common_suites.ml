open Eta

type err = [ `A | `B | `C of int ]
type release_error = Release_error of { kind : string; code : int }

let render_err = function
  | `A -> "A"
  | `B -> "B"
  | `C n -> "C:" ^ string_of_int n

let pp_err fmt err = Format.pp_print_string fmt (render_err err)
let finalizer_fail_string error =
  Cause.Finalizer.Fail { error; pp = Format.pp_print_string }

let test_cause_extractors_and_squash () =
  let id = Cause.fresh_interrupt_id () in
  let defect = Failure "defect" in
  let finalizer_defect = Invalid_argument "cleanup defect" in
  let cause =
    Cause.concurrent
      [
        Cause.fail `A;
        Cause.sequential
          [
            Cause.die defect;
            Cause.interrupt_with_id id;
            Cause.fail (`C 7);
          ];
        Cause.finalizer
          (Cause.Finalizer.Sequential
             [
               finalizer_fail_string "cleanup failed";
               Cause.Finalizer.Die (match Cause.die finalizer_defect with
                   | Cause.Die die -> die
                   | _ -> assert false);
               Cause.Finalizer.Interrupt (Some id);
             ]);
      ]
  in
  Alcotest.(check (list string)) "typed failures" [ "A"; "C:7" ]
    (List.map render_err (Cause.failures cause));
  let defects = Cause.defects cause in
  Alcotest.(check int) "defect count" 2 (List.length defects);
  Alcotest.(check bool) "primary defect" true ((List.nth defects 0).Cause.exn == defect);
  Alcotest.(check bool) "finalizer defect" true
    ((List.nth defects 1).Cause.exn == finalizer_defect);
  let interruptors = Cause.interruptors cause in
  Alcotest.(check int) "deduplicated interruptors" 1 (List.length interruptors);
  Alcotest.(check bool) "interrupt id" true
    (Cause.equal_interrupt_id id (List.hd interruptors));
  match Cause.squash (fun err -> Failure (render_err err)) cause with
  | Failure msg when String.equal msg "A" -> ()
  | exn -> Alcotest.failf "unexpected squash result: %s" (Printexc.to_string exn)

let test_cause_pretty () =
  let cause =
    Cause.sequential
      [
        Cause.fail `A;
        Cause.suppressed ~primary:(Cause.fail `B)
          ~finalizer:(finalizer_fail_string "cleanup failed");
      ]
  in
  Alcotest.(check string)
    "pretty"
    "sequential:\n  fail: A\n  suppressed:\n    primary:\n      fail: B\n    finalizer:\n      finalizer fail: cleanup failed"
    (Cause.pretty render_err cause)

let test_finalizer_fail_preserves_typed_payload_and_leaves_typed_channel () =
  let observed = ref None in
  let pp_observing fmt (Release_error { kind; code } as error) =
    observed := Some error;
    Format.fprintf fmt "%s:%d" kind code
  in
  let original = Release_error { kind = "release"; code = 42 } in
  let finalizer = Cause.finalizer_of_cause pp_observing (Cause.fail original) in
  Alcotest.(check bool) "conversion does not render eagerly" true
    (Option.is_none !observed);
  (match finalizer with
  | Cause.Finalizer.Fail { error; pp } ->
      Alcotest.(check string)
        "stored printer classifies the surviving value" "release:42"
        (Format.asprintf "%a" pp error)
  | _ -> Alcotest.fail "expected typed finalizer failure");
  Alcotest.(check bool) "original concrete value survived" true
    (match !observed with Some error -> error == original | None -> false);
  Alcotest.(check int) "finalizer failure is outside typed channel" 0
    (List.length
       (Cause.failures (Cause.finalizer finalizer : release_error Cause.t)))

let test_portable_finalizer_fail_materializes_stored_printer () =
  let same_domain =
    Cause.finalizer_of_cause pp_err (Cause.fail (`C 7)) |> Cause.finalizer
  in
  match Cause.to_portable Fun.id same_domain with
  | Cause.Portable.Finalizer (Cause.Portable.Finalizer.Fail "C:7") -> ()
  | portable ->
      Alcotest.failf "unexpected portable cause: %a"
        (Cause.Portable.pp pp_err) portable

let colliding_pp fmt _ = Format.pp_print_string fmt "collision"

let test_finalizer_equal_uses_rendered_form_including_collisions () =
  let left = Cause.Finalizer.Fail { error = `A; pp = colliding_pp } in
  let right = Cause.Finalizer.Fail { error = 37; pp = colliding_pp } in
  let distinct =
    Cause.Finalizer.Fail
      { error = `B; pp = (fun fmt _ -> Format.pp_print_string fmt "distinct") }
  in
  Alcotest.(check bool) "different hidden types collide honestly" true
    (Cause.Finalizer.equal left right);
  Alcotest.(check bool) "different rendered forms differ" false
    (Cause.Finalizer.equal left distinct);
  Alcotest.(check bool) "Cause.equal delegates to rendered equality" true
    (Cause.equal (fun _ _ -> false) (Cause.finalizer left)
       (Cause.finalizer right))

let test_finalizer_diagnostic_equal_uses_rendered_form_including_collisions () =
  let left = Cause.Finalizer.Fail { error = `A; pp = colliding_pp } in
  let right = Cause.Finalizer.Fail { error = 37; pp = colliding_pp } in
  let distinct =
    Cause.Finalizer.Fail
      { error = `B; pp = (fun fmt _ -> Format.pp_print_string fmt "distinct") }
  in
  Alcotest.(check bool) "different hidden types collide honestly" true
    (Cause.Finalizer.diagnostic_equal left right);
  Alcotest.(check bool) "different rendered forms differ" false
    (Cause.Finalizer.diagnostic_equal left distinct);
  Alcotest.(check bool) "Cause.diagnostic_equal delegates to rendered equality"
    true
    (Cause.diagnostic_equal (fun _ _ -> false) (Cause.finalizer left)
       (Cause.finalizer right))

let test_exit_combinators () =
  let ok = Exit.ok 21 in
  Alcotest.(check bool) "ok is ok" true (Exit.is_ok ok);
  Alcotest.(check (option int)) "success" (Some 21) (Exit.get_success ok);
  Alcotest.(check string) "match ok" "42"
    (Exit.match_ ~ok:(fun n -> string_of_int (n * 2)) ~error:(fun _ -> "error") ok);
  (match Exit.map (( + ) 1) ok with
  | Exit.Ok 22 -> ()
  | _ -> Alcotest.fail "map did not transform success");
  Alcotest.(check int) "get_or_else ok" 21
    (Exit.get_or_else (fun _ -> 0) ok);
  (match Exit.as_unit ok with
  | Exit.Ok () -> ()
  | _ -> Alcotest.fail "as_unit did not preserve success");
  let error = Exit.error (Cause.sequential [ Cause.fail `A; Cause.fail `B ]) in
  Alcotest.(check bool) "error is error" true (Exit.is_error error);
  Alcotest.(check bool) "cause present" true
    (Option.is_some (Exit.get_cause error));
  Alcotest.(check string) "match error" "error"
    (Exit.match_ ~ok:string_of_int ~error:(fun _ -> "error") error);
  Alcotest.(check int) "get_or_else error" 9
    (Exit.get_or_else (fun _ -> 9) error);
  (match Exit.map_error (function `A -> `C 1 | `B -> `C 2 | `C n -> `C n) error with
  | Exit.Error cause ->
      Alcotest.(check (list string)) "mapped failures" [ "C:1"; "C:2" ]
        (List.map render_err (Cause.failures cause))
  | Exit.Ok _ -> Alcotest.fail "map_error unexpectedly succeeded");
  Alcotest.(check string) "pretty ok" "Ok(21)"
    (Exit.pretty string_of_int render_err ok);
  Alcotest.(check string) "pretty error" "Error(sequential:\n  fail: A\n  fail: B)"
    (Exit.pretty string_of_int render_err error)

let tests =
  [
    ( "Cause",
      [
        Alcotest.test_case "extractors and squash" `Quick
          test_cause_extractors_and_squash;
        Alcotest.test_case "pretty" `Quick test_cause_pretty;
        Alcotest.test_case
          "finalizer fail preserves typed payload and leaves typed channel" `Quick
          test_finalizer_fail_preserves_typed_payload_and_leaves_typed_channel;
        Alcotest.test_case "portable finalizer fail materializes stored printer"
          `Quick test_portable_finalizer_fail_materializes_stored_printer;
        Alcotest.test_case
          "finalizer equal uses rendered form including collisions" `Quick
          test_finalizer_equal_uses_rendered_form_including_collisions;
        Alcotest.test_case
          "finalizer diagnostic equal uses rendered form including collisions"
          `Quick
          test_finalizer_diagnostic_equal_uses_rendered_form_including_collisions;
      ] );
    ( "Exit",
      [ Alcotest.test_case "combinators" `Quick test_exit_combinators ] );
  ]
