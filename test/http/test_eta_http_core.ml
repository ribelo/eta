open Test_eta_http_support

let test_skeleton_loads () =
  Alcotest.(check bool) "loaded" true true

let test_header_value_accepts_htab () =
  let value = "token\twith-tab" in
  Alcotest.(check bool)
    "validate value" true
    (Option.is_none (Eta_http.Core.Header.validate_value value));
  Alcotest.(check bool)
    "valid headers" true
    (Eta_http.Core.Header.valid [ ("X-Eta_test", value) ]);
  match Eta_http.Core.Header.value value with
  | Ok _ -> ()
  | Error _ -> Alcotest.fail "HTAB header value rejected"

let test_error_redaction_and_projection () =
  let uri = "https://api.example.test/v1/models?token=secret#frag" in
  let error =
    Eta_http.Error.make ~protocol:H2 ~method_:"GET" ~uri
      (HTTP_status
         {
           status = 503;
           headers =
             [
               ("authorization", "Bearer secret");
               ("Cookie", "sid=secret-cookie");
               ("Set-Cookie", "sid=secret-cookie");
               ("X-API-Key", "secret-key");
               ("Content-Type", "text/plain");
             ];
         })
  in
  Alcotest.(check string)
    "class" "http_status_5xx" (Eta_http.Error.error_class error);
  Alcotest.(check string)
    "retryability" "retryable_if_body_replayable"
    (Eta_http.Error.retryability_to_string (Eta_http.Error.retryability error));
  let pretty = Eta_http.Error.to_string error in
  let json = Eta_http.Error_projection.to_json error in
  List.iter
    (fun output ->
      Alcotest.(check bool) "redacted marker" true
        (contains output "<redacted>");
      Alcotest.(check bool) "auth secret absent" false
        (contains output "Bearer secret");
      Alcotest.(check bool) "cookie secret absent" false
        (contains output "secret-cookie");
      Alcotest.(check bool) "api key absent" false
        (contains output "secret-key");
      Alcotest.(check bool) "query secret absent" false
        (contains output "secret");
      Alcotest.(check bool) "body omitted" true
        (contains output "body"))
    [ pretty; json ]

