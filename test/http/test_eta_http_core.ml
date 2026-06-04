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

let test_method_of_string_fast_path_semantics () =
  Alcotest.(check string) "known lowercase trimmed" "GET"
    (Eta_http.Core.Method.to_string
       (Eta_http.Core.Method.of_string "  get\t"));
  Alcotest.(check bool) "post not idempotent" false
    (Eta_http.Core.Method.is_idempotent
       (Eta_http.Core.Method.of_string "\r\npost "));
  Alcotest.(check string) "unknown uppercased trimmed" "BREW"
    (Eta_http.Core.Method.to_string
       (Eta_http.Core.Method.of_string " brew "))

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
  let parsed = Yojson.Safe.from_string json in
  Alcotest.(check string) "json method" "GET"
    (Yojson.Safe.Util.member "method" parsed |> Yojson.Safe.Util.to_string);
  Alcotest.(check int) "json status" 503
    (Yojson.Safe.Util.member "status" parsed |> Yojson.Safe.Util.to_int);
  Alcotest.(check string) "json redacted uri"
    "https://api.example.test/v1/models?<redacted>#frag"
    (Yojson.Safe.Util.member "uri" parsed |> Yojson.Safe.Util.to_string);
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

let test_trace_context_request_helpers () =
  let traceparent =
    "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
  in
  let request =
    Eta_http.Request.make
      ~headers:(Eta_http.Core.Header.unsafe_of_list [ ("TraceParent", traceparent) ])
      "GET" "http://example.test/"
  in
  let extracted = Eta_http.Trace_context.extract_request request in
  let ctx =
    match extracted with
    | Some ctx -> ctx
    | None -> Alcotest.fail "expected trace context"
  in
  Alcotest.(check string) "trace id" "4bf92f3577b34da6a3ce929d0e0e4736"
    ctx.trace_id;
  let replacement =
    Option.get
      (Eta.Trace_context.make
         ~trace_id:"11111111111111111111111111111111"
         ~span_id:"2222222222222222" ())
  in
  let injected = Eta_http.Trace_context.inject_request replacement request in
  Alcotest.(check (option string)) "traceparent replaced"
    (Some "00-11111111111111111111111111111111-2222222222222222-01")
    (Eta_http.Core.Header.get "traceparent" injected.Eta_http.Request.headers)
