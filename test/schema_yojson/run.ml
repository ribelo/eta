let test_round_trip () =
  let input =
    `Assoc
      [
        ("null", `Null);
        ("bool", `Bool true);
        ("int", `Int 3);
        ("intlit", `Intlit "9007199254740993");
        ("float", `Float 1.5);
        ("text", `String "value");
        ("array", `List [ `Int 1; `Int 2 ]);
      ]
  in
  let converted = Eta_schema_yojson.of_yojson input |> Result.get_ok in
  Alcotest.(check string)
    "round trip" (Yojson.Safe.to_string input)
    (Eta_schema_yojson.to_yojson converted |> Yojson.Safe.to_string)

let test_reject_non_finite () =
  Alcotest.(check bool)
    "non-finite rejected" true
    (Result.is_error (Eta_schema_yojson.of_yojson (`Float Float.nan)))

let () =
  Alcotest.run "eta_schema_yojson"
    [
      ( "adapter",
        [
          Alcotest.test_case "round trip" `Quick test_round_trip;
          Alcotest.test_case "non-finite number" `Quick test_reject_non_finite;
        ] );
    ]
