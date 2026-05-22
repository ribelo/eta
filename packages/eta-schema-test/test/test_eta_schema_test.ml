open Eta_schema
open Eta_schema_test

let string_schema = Schema.string

let test_decode_ok () =
  check_decode Alcotest.string string_schema (Json.string "ok") "ok"

let test_encode_ok () =
  check_encode string_schema "ok" (Json.string "ok")

let test_decode_error () =
  let issues =
    Schema.decode string_schema (Json.int 1)
    |> run_effect
    |> expect_decode_error ~name:"string decode"
  in
  Alcotest.(check int) "issue count" 1 (List.length issues);
  match List.hd issues with
  | { kind = Type_mismatch { expected = "string"; _ }; _ } -> ()
  | issue ->
      Alcotest.failf "unexpected issue: %s" (render_issue issue)

let test_encode_error () =
  let one = Schema.enum ~name:"one" [ ("one", 1) ] ~equal:Int.equal in
  let issues =
    Schema.encode one 2 |> run_effect |> expect_encode_error ~name:"one encode"
  in
  Alcotest.(check int) "issue count" 1 (List.length issues)

let test_roundtrip_json () =
  check_roundtrip_json string_schema (Json.string "roundtrip")

let test_effect_subset_policy () =
  let policy value =
    Eta.Effect.named "policy" (Eta.Effect.sync (fun () -> value ^ "!"))
  in
  let result =
    Schema.decode_with_policy string_schema policy (Json.string "ok")
    |> run_effect
  in
  Alcotest.(check string) "policy result" "ok!" (expect_ok result)

let () =
  Alcotest.run "eta-schema-test"
    [
      ( "Expect",
        [
          Alcotest.test_case "decode ok" `Quick test_decode_ok;
          Alcotest.test_case "encode ok" `Quick test_encode_ok;
          Alcotest.test_case "decode error" `Quick test_decode_error;
          Alcotest.test_case "encode error" `Quick test_encode_error;
          Alcotest.test_case "roundtrip json" `Quick test_roundtrip_json;
          Alcotest.test_case "effect subset policy" `Quick
            test_effect_subset_policy;
        ] );
    ]
