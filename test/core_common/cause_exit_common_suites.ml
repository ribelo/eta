open Eta

type err = [ `A | `B | `C of int ]

let render_err = function
  | `A -> "A"
  | `B -> "B"
  | `C n -> "C:" ^ string_of_int n

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
               Cause.Finalizer.Fail "cleanup failed";
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
          ~finalizer:(Cause.Finalizer.Fail "cleanup failed");
      ]
  in
  Alcotest.(check string)
    "pretty"
    "sequential:\n  fail: A\n  suppressed:\n    primary:\n      fail: B\n    finalizer:\n      finalizer fail: cleanup failed"
    (Cause.pretty render_err cause)

let test_exit_combinators () =
  let ok = Exit.Ok 21 in
  (match Exit.map (( + ) 1) ok with
  | Exit.Ok 22 -> ()
  | _ -> Alcotest.fail "map did not transform success");
  let error =
    Exit.Error (Cause.sequential [ Cause.fail `A; Cause.fail `B ])
  in
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
      ] );
    ( "Exit",
      [ Alcotest.test_case "combinators" `Quick test_exit_combinators ] );
  ]
