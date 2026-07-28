open Eta

let check expected eff =
  Alcotest.(check string) expected expected (Effect.describe eff)

let test_constructor_tree_without_evaluation () =
  let custom_forced = ref false in
  let custom : (unit, string) Effect.t =
    Effect.Expert.make (fun _ ->
        custom_forced := true;
        Exit.Ok ())
  in
  check "Pure" (Effect.pure ());
  check "Fail" (Effect.fail "failure");
  check "Custom" custom;
  Alcotest.(check bool) "custom evaluator remains opaque" false !custom_forced;
  check "Custom(\"named.custom\")"
    (Effect.Expert.make ~leaf_name:"named.custom" (fun _ -> Exit.Ok ()));
  check "Map\n  Pure" (Effect.map (( + ) 1) (Effect.pure 1));
  let continuation_forced = ref false in
  let bound =
    Effect.bind
      (fun () ->
        continuation_forced := true;
        Effect.unit)
      Effect.unit
  in
  check "Bind\n  Pure\n  <bind …>" bound;
  Alcotest.(check bool)
    "bind continuation remains opaque" false !continuation_forced;
  check "Custom(\"Effect.uninterruptible\")"
    (Effect.uninterruptible (Effect.map Fun.id Effect.unit));
  let description = Effect.describe bound in
  Alcotest.(check bool)
    "description has no trailing newline" false
    (String.ends_with ~suffix:"\n" description)

let () =
  Alcotest.run "effect introspection"
    [
      ( "describe",
        [
          Alcotest.test_case
            "constructor tree is exact and inspection does not evaluate" `Quick
            test_constructor_tree_without_evaluation;
        ] );
    ]
