module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  open Eta_schema
  open Eta_schema_test

  let string_schema = Eta_schema.string

  let test_decode_ok () =
    check_decode Alcotest.string string_schema (Json.string "ok") "ok"

  let test_encode_ok () =
    check_encode string_schema "ok" (Json.string "ok")

  let test_decode_error () =
    B.with_runtime @@ fun _ctx rt ->
    let issues =
      Eta_schema.decode string_schema (Json.int 1)
      |> run_effect (B.run rt)
      |> expect_decode_error ~name:"string decode"
    in
    Alcotest.(check int) "issue count" 1 (List.length issues);
    match List.hd issues with
    | { kind = Type_mismatch { expected = "string"; _ }; _ } -> ()
    | issue ->
        Alcotest.failf "unexpected issue: %s" (render_issue issue)

  let test_encode_error () =
    B.with_runtime @@ fun _ctx rt ->
    let one = Eta_schema.enum ~name:"one" [ ("one", 1) ] ~equal:Int.equal in
    let issues =
      Eta_schema.encode one 2 |> run_effect (B.run rt)
      |> expect_encode_error ~name:"one encode"
    in
    Alcotest.(check int) "issue count" 1 (List.length issues)

  let test_roundtrip_json () =
    check_roundtrip_json string_schema (Json.string "roundtrip")

  let test_effect_subset_policy () =
    B.with_runtime @@ fun _ctx rt ->
    let policy value =
      Eta.Effect.named "policy" (Eta.Effect.sync (fun () -> value ^ "!"))
    in
    let program =
      Eta_schema.decode_with_policy string_schema policy (Json.string "ok")
    in
    Alcotest.(check string) "policy result" "ok!"
      (expect_ok (run_effect (B.run rt) program))

  let tests =
    [
      ( "Expect",
        [
          Alcotest.test_case "decode ok" `Quick test_decode_ok;
          Alcotest.test_case "encode ok" `Quick test_encode_ok;
          Alcotest.test_case "decode error" `Quick test_decode_error;
          Alcotest.test_case "encode error" `Quick test_encode_error;
          Alcotest.test_case "roundtrip json" `Quick test_roundtrip_json;
          Alcotest.test_case "eff subset policy" `Quick
            test_effect_subset_policy;
        ] );
    ]
end
