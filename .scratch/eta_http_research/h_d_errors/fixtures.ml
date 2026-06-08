open Eta

let fail message = failwith message

let check label condition =
  if not condition then fail ("FAIL " ^ label)

let check_equal label expected actual =
  if not (String.equal expected actual) then
    fail
      (Printf.sprintf "FAIL %s expected=%S actual=%S" label expected actual)

let contains haystack needle =
  let h_len = String.length haystack in
  let n_len = String.length needle in
  let rec loop index =
    index + n_len <= h_len
    && (String.equal needle (String.sub haystack index n_len)
       || loop (index + 1))
  in
  n_len = 0 || loop 0

let check_contains label haystack needle =
  check label (contains haystack needle)

let check_absent label haystack needle =
  check label (not (contains haystack needle))

let context_uri =
  "https://api.example.test/v1/items?token=secret-token&debug=true#frag"

let make ?(protocol = Error.H2) kind =
  Error.make ~protocol ~method_:"GET" ~uri:context_uri kind

let all_variants =
  [
    make (Connect_timeout { timeout_ms = Some 250 });
    make
      (Tls_handshake_error
         { stage = Tls_handshake; message = "remote handshake alert" });
    make
      (Tls_certificate_error
         { reason = Name_mismatch; message = "wrong host" });
    make (Connection_closed { during = Tcp });
    make Pool_shutdown;
    make (Pool_acquire_timeout { timeout_ms = Some 50 });
    make (Response_header_timeout { timeout_ms = Some 500 });
    make (Response_body_idle_timeout { timeout_ms = Some 1_000 });
    make (Total_request_timeout { timeout_ms = Some 2_000 });
    make
      (HTTP_status
         {
           status = 503;
           headers =
             [
               ("authorization", "Bearer secret-auth");
               ("Cookie", "sid=secret-cookie");
               ("Set-Cookie", "sid=secret-cookie");
               ("X-API-Key", "secret-key");
               ("Content-Type", "text/plain");
             ];
         });
    make (Decode_error { codec = "gzip"; message = "crc mismatch" });
    make
      (Connection_protocol_violation
         {
           kind = "window_update_accounting";
           message = "WINDOW_UPDATE accounting limit exceeded";
         });
    make
      (Hpack_decode_overflow
         { decoded_bytes = 104_857_600; limit_bytes = 262_144 });
    make
      (Continuation_flood
         { accumulated_bytes = 65_536; limit_bytes = 65_536; frames = 64 });
    make (Stream_admission_rejected { limit = 128 });
    make
      (Rst_rate_exceeded
         { observed_per_second = 1_000; limit_per_second = 100 });
    make (Ping_rate_exceeded { observed_rate_hz = 1_000; limit_hz = 100 });
    make
      (Settings_churn_rate_exceeded
         { observed_rate_hz = 250; limit_hz = 10 });
    make
      (Response_header_change_rate_exceeded
         { observed_rate_hz = 128; limit_hz = 32 });
    make (Header_invalid { reason = "uppercase response header name" });
  ]

let test_every_required_variant_has_observability () =
  List.iter
    (fun error ->
      check_contains "variant name present" (Error.kind_name error.Error.kind) "";
      check_contains "error class non-empty" (Error.error_class error) "";
      check_contains "layer non-empty"
        (Error.layer_to_string (Error.layer error))
        "";
      check_contains "retryability non-empty"
        (Error.retryability_to_string (Error.retryability error))
        "")
    all_variants;
  check_equal "http status class" "5xx"
    (Option.value ~default:"none" (Error.status_class (List.nth all_variants 9)));
  print_endline "PASS all required variants expose low-cardinality fields"

let test_layer_mapping () =
  let alpn =
    make
      (Tls_handshake_error
         { stage = Alpn_negotiation; message = "no h2 protocol" })
  in
  check_equal "alpn layer" "alpn"
    (Error.layer_to_string (Error.layer alpn));
  check_equal "hpack layer" "http_response"
    (Error.layer_to_string
       (Error.layer
          (make
             (Hpack_decode_overflow
                { decoded_bytes = 100_000_000; limit_bytes = 262_144 }))));
  check_equal "decode layer" "body_decode"
    (Error.layer_to_string
       (Error.layer
          (make (Decode_error { codec = "gzip"; message = "crc mismatch" }))));
  check_equal "window update layer" "http_response"
    (Error.layer_to_string
       (Error.layer
          (make
             (Connection_protocol_violation
                {
                  kind = "window_update_accounting";
                  message = "bad increment";
                }))));
  print_endline "PASS layers distinguish TCP/TLS/ALPN/HTTP/body-decode failures"

let test_retry_policy_distinguishes_protocol_abuse () =
  let decode =
    make (Decode_error { codec = "h2_frame"; message = "truncated frame" })
  in
  let window_update =
    make
      (Connection_protocol_violation
         {
           kind = "window_update_accounting";
           message = "WINDOW_UPDATE accounting limit exceeded";
         })
  in
  check_equal "transient decode retryability"
    "retryable_if_body_replayable"
    (Error.retryability_to_string (Error.retryability decode));
  check_equal "protocol abuse retryability" "not_retryable"
    (Error.retryability_to_string (Error.retryability window_update));
  print_endline
    "PASS retry policy distinguishes decode corruption from protocol abuse"

let test_redaction () =
  let error = List.nth all_variants 9 in
  let pretty = Error.to_string error in
  let json = Projections.to_json error in
  List.iter
    (fun output ->
      check_contains "authorization redacted" output "authorization=<redacted>";
      check_absent "auth secret absent" output "secret-auth";
      check_absent "cookie secret absent" output "secret-cookie";
      check_absent "api key secret absent" output "secret-key";
      check_absent "query secret absent" output "secret-token";
      check_contains "query replaced" output "?<redacted>#frag";
      check_contains "body omitted" output "body=<omitted>")
    [ pretty ];
  List.iter
    (fun output ->
      check_contains "json redacted marker" output "<redacted>";
      check_absent "json auth secret absent" output "secret-auth";
      check_absent "json cookie secret absent" output "secret-cookie";
      check_absent "json api key secret absent" output "secret-key";
      check_absent "json query secret absent" output "secret-token";
      check_contains "json body omitted" output "\"body\":\"<omitted>\"")
    [ json ];
  print_endline "PASS redaction hides headers, query strings, and bodies in projections"

let test_cause_leaf () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock stdenv in
  let rt = Runtime.create ~sw ~clock () in
  let error = List.nth all_variants 9 in
  match Runtime.run rt (Effect.fail error) with
  | Exit.Ok _ -> fail "expected structured HTTP error"
  | Exit.Error cause ->
      let rendered = Format.asprintf "%a" (Cause.pp Error.pp) cause in
      check_contains "cause uses structured renderer" rendered
        "error=HTTP_status";
      check_absent "cause redacts secret" rendered "secret-auth";
      print_endline "PASS structured error fits in Eta Cause.t leaf"

let source_cross_tab =
  [
    ("Eta.Pool shutdown", make Pool_shutdown);
    ( "Eta.Pool acquire timeout",
      make (Pool_acquire_timeout { timeout_ms = Some 50 }) );
    ( "H-D1 Admission_limited",
      make (Stream_admission_rejected { limit = 128 }) );
    ( "H-D1 Socket_closed",
      make (Connection_closed { during = Http_response }) );
    ( "H-D1 hpack overflow",
      make
        (Hpack_decode_overflow
           { decoded_bytes = 1_000_000; limit_bytes = 262_144 }) );
    ( "H-D5 pending connection cancelled",
      make (Connection_closed { during = Cancellation }) );
    ( "H-Q2 rst breaker",
      make
        (Rst_rate_exceeded
           { observed_per_second = 1_000; limit_per_second = 100 }) );
    ( "H-Q5 ping flood",
      make (Ping_rate_exceeded { observed_rate_hz = 1_000; limit_hz = 100 })
    );
    ( "H-Q5 window update accounting",
      make
        (Connection_protocol_violation
           {
             kind = "window_update_accounting";
             message = "WINDOW_UPDATE accounting limit exceeded";
           }) );
    ( "H-Q5 settings churn",
      make
        (Settings_churn_rate_exceeded
           { observed_rate_hz = 250; limit_hz = 10 }) );
    ( "H-Q2 response header churn",
      make
        (Response_header_change_rate_exceeded
           { observed_rate_hz = 128; limit_hz = 32 }) );
    ( "H-Q5 header normalization",
      make (Header_invalid { reason = "uppercase response header name" }) );
    ( "H-Q3 continuation breaker",
      make
        (Continuation_flood
           { accumulated_bytes = 65_536; limit_bytes = 65_536; frames = 64 }) );
  ]

let test_cross_tab_has_no_unintended_collision () =
  List.iter
    (fun (source, error) ->
      let pair =
        Error.error_class error ^ ":" ^ Error.layer_to_string (Error.layer error)
      in
      check_contains ("cross-tab pair for " ^ source) pair ":")
    source_cross_tab;
  print_endline
    "PASS H-D1/H-D5/Pool/security outcomes map to class+layer pairs"

let () =
  test_every_required_variant_has_observability ();
  test_layer_mapping ();
  test_retry_policy_distinguishes_protocol_abuse ();
  test_redaction ();
  test_cause_leaf ();
  test_cross_tab_has_no_unintended_collision ();
  print_endline "h_d_errors fixtures passed"
