type schema_error = Eta_schema.error

let json_testable =
  Alcotest.testable
    (fun fmt json -> Format.pp_print_string fmt (Eta_schema.Json.to_string json))
    Eta_schema.Json.equal

let issue_testable =
  Alcotest.testable
    (fun fmt issue -> Format.pp_print_string fmt (Eta_schema.render_issue issue))
    ( = )

let issues_testable = Alcotest.list issue_testable

let run_effect eff =
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  match Eta.Runtime.run rt eff with
  | Eta.Exit.Ok value -> Ok value
  | Eta.Exit.Error (Eta.Cause.Fail error) -> Error error
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected schema effect failure: %a"
        (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<schema-error>"))
        cause

let fail_issues name kind issues =
  Alcotest.failf "%s: %s: %s" name kind (Eta_schema.render_issues issues)

let expect_ok ?(name = "schema") = function
  | Ok value -> value
  | Error (`Decode issues) -> fail_issues name "decode failed" issues
  | Error (`Encode issues) -> fail_issues name "encode failed" issues

let expect_decode_error ?(name = "schema") = function
  | Ok _ -> Alcotest.failf "%s: expected decode failure" name
  | Error (`Decode issues) -> issues
  | Error (`Encode _) ->
      Alcotest.failf "%s: expected decode failure, got encode failure" name

let expect_encode_error ?(name = "schema") = function
  | Ok _ -> Alcotest.failf "%s: expected encode failure" name
  | Error (`Encode issues) -> issues
  | Error (`Decode _) ->
      Alcotest.failf "%s: expected encode failure, got decode failure" name

let decode_ok ?(name = "decode") schema value =
  Eta_schema.Eta_schema.decode schema value |> run_effect |> expect_ok ~name

let encode_ok ?(name = "encode") schema value =
  Eta_schema.Eta_schema.encode schema value |> run_effect |> expect_ok ~name

let check_decode testable ?(name = "decode") schema json expected =
  Alcotest.check testable name expected (decode_ok ~name schema json)

let check_encode ?(name = "encode") schema value expected =
  Alcotest.check json_testable name expected (encode_ok ~name schema value)

let check_roundtrip_json ?(name = "roundtrip") schema json_value =
  let decoded = decode_ok ~name schema json_value in
  Alcotest.check json_testable name json_value (encode_ok ~name schema decoded)
