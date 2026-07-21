open Eta

(* Snapshot corpus for Cause.pretty and Cause.pp_compact. Expected strings are
   locked renders: any rendering drift fails this suite. Interrupt ids are
   abstract, so expectations containing ids are assembled from single-node
   fragments rendered through the same function under test. *)

type err = [ `A | `B | `C of int | `Nl ]

let render_err = function
  | `A -> "A"
  | `B -> "B"
  | `C n -> "C:" ^ string_of_int n
  | `Nl -> "x\ny"

let die_record exn =
  match Cause.die exn with Cause.Die die -> die | _ -> assert false

(* [die]s rendering after anti-counterfeit quoting: the exception message is
   quoted whenever it contains grammar-structural characters. *)
let die_s exn = "die(" ^ Printf.sprintf "%S" (Printexc.to_string exn) ^ ")"

let check_case name cause ~pretty ~compact =
  Alcotest.(check string) (name ^ " (pretty)") pretty
    (Cause.pretty render_err cause);
  Alcotest.(check string) (name ^ " (compact)") compact
    (Cause.pp_compact render_err cause)

(* The five one-pager corpus cases. *)

let test_corpus_concurrent_fail_interrupt () =
  check_case "concurrent fail+interrupt"
    (Cause.concurrent [ Cause.fail `A; Cause.interrupt ])
    ~pretty:"concurrent:\n  fail: A\n  interrupt"
    ~compact:"fail(A) + interrupt"

let test_corpus_suppressed_fail_die () =
  check_case "suppressed fail+die"
    (Cause.suppressed ~primary:(Cause.fail `B)
       ~finalizer:(Cause.Finalizer.Die (die_record (Invalid_argument "cleanup"))))
    ~pretty:
      "suppressed:\n  primary:\n    fail: B\n  finalizer:\n    defect: \
       Invalid_argument(\"cleanup\")"
    ~compact:("fail(B) | suppressed: finalizer(" ^ die_s (Invalid_argument "cleanup") ^ ")")

let test_corpus_nested_finalizer_sequential () =
  let id = Cause.fresh_interrupt_id () in
  let pretty_id =
    "interrupt: " ^ string_of_int (Cause.interrupt_id_to_int id)
  in
  let compact_id =
    "interrupt#" ^ string_of_int (Cause.interrupt_id_to_int id)
  in
  check_case "nested finalizer sequential"
    (Cause.finalizer
       (Cause.Finalizer.Sequential
          [
            Cause.Finalizer.Fail "cleanup failed";
            Cause.Finalizer.Die (die_record (Invalid_argument "cleanup defect"));
            Cause.Finalizer.Interrupt (Some id);
          ]))
    ~pretty:
      ("finalizer:\n  sequential:\n    finalizer fail: cleanup failed\n    \
        defect: Invalid_argument(\"cleanup defect\")\n    " ^ pretty_id)
    ~compact:
      ("finalizer(fail(\"cleanup failed\") ; \
        " ^ die_s (Invalid_argument "cleanup defect") ^ " ; " ^ compact_id ^ ")")

let test_corpus_interrupts_anonymous_vs_identified () =
  let id = Cause.fresh_interrupt_id () in
  let pretty_id =
    "interrupt: " ^ string_of_int (Cause.interrupt_id_to_int id)
  in
  let compact_id =
    "interrupt#" ^ string_of_int (Cause.interrupt_id_to_int id)
  in
  Alcotest.(check string) "anonymous interrupt (pretty)" "interrupt"
    (Cause.pretty render_err Cause.interrupt);
  Alcotest.(check string) "anonymous interrupt (compact)" "interrupt"
    (Cause.pp_compact render_err Cause.interrupt);
  Alcotest.(check string) "identified interrupt (pretty)" pretty_id
    (Cause.pretty render_err (Cause.interrupt_with_id id));
  Alcotest.(check string) "identified interrupt (compact)" compact_id
    (Cause.pp_compact render_err (Cause.interrupt_with_id id))

let test_corpus_leaf_cannot_counterfeit_composite () =
  let spoof = "A) + interrupt ; fail(B" in
  let render_spoof = function `A -> spoof | _ -> assert false in
  Alcotest.(check string)
    "compact quotes structural fail text"
    ("fail(" ^ Printf.sprintf "%S" spoof ^ ")")
    (Cause.pp_compact render_spoof (Cause.fail `A));
  Alcotest.(check string)
    "compact quotes structural die message"
    (die_s (Failure "x) + interrupt"))
    (Cause.pp_compact render_spoof (Cause.die (Failure "x) + interrupt")))

let test_corpus_multi_defect_composite () =
  check_case "multi-defect composite"
    (Cause.concurrent
       [ Cause.die (Failure "a"); Cause.die (Failure "b") ])
    ~pretty:"concurrent:\n  defect: Failure(\"a\")\n  defect: Failure(\"b\")"
    ~compact:(die_s (Failure "a") ^ " + " ^ die_s (Failure "b"))

(* Ugly composites: suppressed x concurrent x finalizer, parenthesization. *)

let test_corpus_suppressed_concurrent_finalizer () =
  check_case "suppressed x concurrent x finalizer"
    (Cause.suppressed
       ~primary:
         (Cause.concurrent [ Cause.fail `A; Cause.die (Failure "boom") ])
       ~finalizer:
         (Cause.Finalizer.Sequential
            [ Cause.Finalizer.Fail "cleanup failed"; Cause.Finalizer.Interrupt None ]))
    ~pretty:
      "suppressed:\n  primary:\n    concurrent:\n      fail: A\n      defect: \
       Failure(\"boom\")\n  finalizer:\n    sequential:\n      finalizer fail: \
       cleanup failed\n      interrupt"
    ~compact:
      ("fail(A) + " ^ die_s (Failure "boom")
      ^ " | suppressed: finalizer(fail(\"cleanup failed\") ; interrupt)")

let test_corpus_mixed_nesting_parens () =
  check_case "mixed nesting parenthesizes"
    (Cause.sequential
       [ Cause.concurrent [ Cause.fail `A; Cause.fail `B ]; Cause.fail (`C 3) ])
    ~pretty:"sequential:\n  concurrent:\n    fail: A\n    fail: B\n  fail: C:3"
    ~compact:"(fail(A) + fail(B)) ; fail(C:3)"

let test_corpus_suppressed_primary_suppressed () =
  check_case "suppressed primary suppressed"
    (Cause.suppressed
       ~primary:
         (Cause.suppressed ~primary:(Cause.fail `A)
            ~finalizer:(Cause.Finalizer.Fail "f1"))
       ~finalizer:(Cause.Finalizer.Fail "f2"))
    ~pretty:
      "suppressed:\n  primary:\n    suppressed:\n      primary:\n        fail: \
       A\n      finalizer:\n        finalizer fail: f1\n  finalizer:\n    \
       finalizer fail: f2"
    ~compact:"(fail(A) | suppressed: finalizer(fail(\"f1\"))) | suppressed: finalizer(fail(\"f2\"))"

let test_corpus_newline_sanitization () =
  check_case "newline sanitization"
    (Cause.sequential
       [
         Cause.fail `Nl;
         Cause.finalizer (Cause.Finalizer.Fail "line1\nline2");
       ])
    ~pretty:
      "sequential:\n  fail: x\ny\n  finalizer:\n    finalizer fail: line1\n\
       line2"
    ~compact:"fail(x\\ny) ; finalizer(fail(\"line1\\nline2\"))"

let test_corpus_empty_and_singleton_raw_composites () =
  Alcotest.(check string) "empty sequential (compact)" "sequential()"
    (Cause.pp_compact render_err (Cause.Sequential []));
  Alcotest.(check string) "empty concurrent (compact)" "concurrent()"
    (Cause.pp_compact render_err (Cause.Concurrent []));
  Alcotest.(check string) "singleton sequential (compact)" "fail(A)"
    (Cause.pp_compact render_err (Cause.Sequential [ Cause.fail `A ]));
  Alcotest.(check string) "singleton concurrent (compact)" "fail(A)"
    (Cause.pp_compact render_err (Cause.Concurrent [ Cause.fail `A ]))

(* Newline-freedom property: exhaustive bounded enumeration. *)

let fin_leaves =
  [
    Cause.Finalizer.Fail "cleanup failed";
    Cause.Finalizer.Fail "line1\nline2";
    Cause.Finalizer.Die (die_record (Failure "fin boom"));
    Cause.Finalizer.Die (die_record (Invalid_argument "bad\narg"));
    Cause.Finalizer.Interrupt None;
    Cause.Finalizer.Interrupt (Some (Cause.fresh_interrupt_id ()));
  ]

let leaves =
  [
    Cause.fail `A;
    Cause.fail `Nl;
    Cause.die (Failure "boom");
    Cause.die (Invalid_argument "bad\narg");
    Cause.die Not_found;
    Cause.die Exit;
    Cause.interrupt;
    Cause.interrupt_with_id (Cause.fresh_interrupt_id ());
  ]

let take n list =
  let rec go acc n = function
    | [] -> List.rev acc
    | x :: rest -> if n <= 0 then List.rev acc else go (x :: acc) (n - 1) rest
  in
  go [] n list

let fin_nodes =
  let pairs = take 3 fin_leaves in
  fin_leaves
  @ List.concat_map
      (fun a -> List.map (fun b -> Cause.Finalizer.Sequential [ a; b ]) pairs)
      pairs
  @ List.concat_map
      (fun a -> List.map (fun b -> Cause.Finalizer.Concurrent [ a; b ]) pairs)
      pairs
  @ List.map (fun a -> Cause.Finalizer.Finalizer a) pairs
  @ List.concat_map
      (fun a ->
        List.map
          (fun b -> Cause.Finalizer.Suppressed { primary = a; finalizer = b })
          pairs)
      pairs

let level1 =
  let pairs = take 4 leaves in
  let fins = take 6 fin_nodes in
  leaves
  @ List.concat_map
      (fun a -> List.map (fun b -> Cause.sequential [ a; b ]) pairs)
      pairs
  @ List.concat_map
      (fun a -> List.map (fun b -> Cause.concurrent [ a; b ]) pairs)
      pairs
  @ List.map (fun f -> Cause.finalizer f) fins
  @ List.concat_map
      (fun a -> List.map (fun f -> Cause.suppressed ~primary:a ~finalizer:f) fins)
      pairs
  @ [ Cause.Sequential []; Cause.Concurrent [] ]
  @ [ Cause.Sequential [ Cause.fail `A ]; Cause.Concurrent [ Cause.fail `A ] ]

let level2 =
  let sample =
    List.filteri (fun index _ -> index mod 7 = 0) level1
  in
  let fins = take 6 fin_nodes in
  List.concat_map
    (fun a -> List.map (fun b -> Cause.sequential [ a; b ]) sample)
    sample
  @ List.concat_map
      (fun a -> List.map (fun b -> Cause.concurrent [ a; b ]) sample)
      sample
  @ List.concat_map
      (fun a -> List.map (fun f -> Cause.suppressed ~primary:a ~finalizer:f) fins)
      sample

let corpus = level1 @ level2

let test_compact_newline_freedom_property () =
  List.iter
    (fun cause ->
      let rendered = Cause.pp_compact render_err cause in
      if String.length rendered = 0 then
        Alcotest.fail "pp_compact rendered an empty string";
      if String.contains rendered '\n' || String.contains rendered '\r' then
        Alcotest.failf "pp_compact emitted a raw newline: %S" rendered)
    corpus;
  Alcotest.(check bool) "corpus is non-trivial" true
    (List.length corpus > 300)

let test_pretty_multiline_sanity () =
  let rendered =
    Cause.pretty render_err
      (Cause.concurrent [ Cause.fail `A; Cause.fail `B ])
  in
  Alcotest.(check bool) "pretty stays multi-line" true
    (String.contains rendered '\n')

let tests =
  [
    ( "Cause.render",
      [
        Alcotest.test_case "corpus concurrent fail+interrupt" `Quick
          test_corpus_concurrent_fail_interrupt;
        Alcotest.test_case "corpus suppressed fail+die" `Quick
          test_corpus_suppressed_fail_die;
        Alcotest.test_case "corpus nested finalizer sequential" `Quick
          test_corpus_nested_finalizer_sequential;
        Alcotest.test_case "corpus interrupts anonymous vs identified" `Quick
          test_corpus_interrupts_anonymous_vs_identified;
        Alcotest.test_case "corpus leaf cannot counterfeit composite" `Quick
          test_corpus_leaf_cannot_counterfeit_composite;
        Alcotest.test_case "corpus multi-defect composite" `Quick
          test_corpus_multi_defect_composite;
        Alcotest.test_case "corpus suppressed x concurrent x finalizer" `Quick
          test_corpus_suppressed_concurrent_finalizer;
        Alcotest.test_case "corpus mixed nesting parenthesizes" `Quick
          test_corpus_mixed_nesting_parens;
        Alcotest.test_case "corpus suppressed primary suppressed" `Quick
          test_corpus_suppressed_primary_suppressed;
        Alcotest.test_case "corpus newline sanitization" `Quick
          test_corpus_newline_sanitization;
        Alcotest.test_case "corpus empty and singleton raw composites" `Quick
          test_corpus_empty_and_singleton_raw_composites;
        Alcotest.test_case "compact newline-freedom property" `Quick
          test_compact_newline_freedom_property;
        Alcotest.test_case "pretty stays multi-line" `Quick
          test_pretty_multiline_sanity;
      ] );
  ]
