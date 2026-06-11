module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  let contains haystack needle =
    let h_len = String.length haystack in
    let n_len = String.length needle in
    let rec loop index =
      index + n_len <= h_len
      && (String.equal needle (String.sub haystack index n_len)
         || loop (index + 1))
    in
    n_len = 0 || loop 0

  let expect_ok = function
    | Eta.Exit.Ok value -> value
    | Eta.Exit.Error cause ->
        Alcotest.failf "expected Ok, got %a"
          (Eta.Cause.pp Eta_http.Error.pp)
          cause

  let body_size_cap = 1_048_576

  let test_skeleton_loads () =
    Alcotest.(check bool) "loaded" true true

  let expect_body_too_large label ~limit = function
    | Eta.Exit.Error
        (Eta.Cause.Fail
          { Eta_http.Error.kind = Body_too_large { limit = actual; length }; _ }) ->
        Alcotest.(check int) (label ^ " limit") limit actual;
        Alcotest.(check bool) (label ^ " length") true (length > limit)
    | Eta.Exit.Ok body ->
        Alcotest.failf "%s accepted %d bytes" label (Bytes.length body)
    | Eta.Exit.Error cause ->
        Alcotest.failf "%s unexpected failure: %a" label
          (Eta.Cause.pp Eta_http.Error.pp)
          cause

  let retry_response ?(headers = []) ?(release = fun () -> Eta.Effect.unit)
      status =
    Eta_http.Response.make ~status ~headers
      ~body:(Eta_http.Body.Stream.of_bytes ~release [])
      ()

  let retry_client responses =
    let attempts = ref 0 in
    let request _ =
      let index = min !attempts (Array.length responses - 1) in
      incr attempts;
      Eta.Effect.pure (responses.(index) ())
    in
    ( attempts,
      Eta_http.Client.make_custom ~protocol:Eta_http.Client.H1 ~request
        ~stats:(fun () ->
          Eta.Effect.pure
            {
              Eta_http.Client.protocol = H1;
              active = 0;
              idle = 0;
              capacity = 0;
              opened = !attempts;
              released = 0;
            })
        ~shutdown:(fun () -> Eta.Effect.unit) )

  let read_file path =
    let input = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr input)
      (fun () -> really_input_string input (in_channel_length input))

  let find_source label candidates =
    match List.find_opt Sys.file_exists candidates with
    | Some path -> path
    | None ->
        Alcotest.failf "could not locate %s from %s" label (Sys.getcwd ())

  let rec find_sub_from haystack ~needle index =
    let haystack_len = String.length haystack in
    let needle_len = String.length needle in
    if index + needle_len > haystack_len then None
    else if String.sub haystack index needle_len = needle then Some index
    else find_sub_from haystack ~needle (index + 1)

  let find_sub haystack ~needle = find_sub_from haystack ~needle 0

  let require_sub haystack ~needle =
    match find_sub haystack ~needle with
    | Some index -> index
    | None -> Alcotest.failf "missing source marker: %s" needle

  let find_ws_source file =
    find_source file
      [
        "lib/http/ws/" ^ file;
        "lib/http_eio/ws/" ^ file;
        "../lib/http/ws/" ^ file;
        "../lib/http_eio/ws/" ^ file;
        "../../lib/http/ws/" ^ file;
        "../../lib/http_eio/ws/" ^ file;
        "../../../lib/http/ws/" ^ file;
        "../../../lib/http_eio/ws/" ^ file;
      ]

  let find_http_client_source () =
    find_source "client.ml"
      [
        "lib/http_eio/client.ml";
        "lib/http/client/client.ml";
        "../lib/http_eio/client.ml";
        "../lib/http/client/client.ml";
        "../../lib/http_eio/client.ml";
        "../../lib/http/client/client.ml";
        "../../../lib/http_eio/client.ml";
        "../../../lib/http/client/client.ml";
      ]

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
        Alcotest.(check bool) "body omitted" true (contains output "body"))
      [ pretty; json ]

  let test_trace_context_request_helpers () =
    let traceparent =
      "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    in
    let request =
      Eta_http.Request.make
        ~headers:
          (Eta_http.Core.Header.unsafe_of_list [ ("TraceParent", traceparent) ])
        "GET" "http://example.test/"
    in
    let ctx =
      match Eta_http.Trace_context.extract_request request with
      | Some ctx -> ctx
      | None -> Alcotest.fail "expected trace context"
    in
    Alcotest.(check string) "trace id"
      "4bf92f3577b34da6a3ce929d0e0e4736" ctx.trace_id;
    let replacement =
      Option.get
        (Eta.Trace_context.make
           ~trace_id:"11111111111111111111111111111111"
           ~span_id:"2222222222222222" ())
    in
    let injected = Eta_http.Trace_context.inject_request replacement request in
    Alcotest.(check (option string)) "traceparent replaced"
      (Some "00-11111111111111111111111111111111-2222222222222222-01")
      (Eta_http.Core.Header.get "traceparent"
         injected.Eta_http.Request.headers)

  let test_url_parse_client_subset () =
    let url =
      Eta_http.Core.Url.of_string
        "HTTPS://API.Example.test:8443/v1/models?limit=1#top"
    in
    Alcotest.(check string) "scheme" "https"
      (Eta_http.Core.Url.scheme_to_string (Eta_http.Core.Url.scheme url));
    Alcotest.(check string) "host lowercased" "api.example.test"
      (Eta_http.Core.Url.host url);
    Alcotest.(check (option int)) "port" (Some 8443)
      (Eta_http.Core.Url.port url);
    Alcotest.(check int) "effective port" 8443
      (Eta_http.Core.Url.effective_port url);
    Alcotest.(check string) "path" "/v1/models" (Eta_http.Core.Url.path url);
    Alcotest.(check (option string)) "query" (Some "limit=1")
      (Eta_http.Core.Url.query url);
    Alcotest.(check (option string)) "fragment" (Some "top")
      (Eta_http.Core.Url.fragment url);
    Alcotest.(check string) "origin form" "/v1/models?limit=1"
      (Eta_http.Core.Url.origin_form url);
    Alcotest.(check string) "authority" "api.example.test:8443"
      (Eta_http.Core.Url.authority url)

  let test_url_rejects_unsupported_forms () =
    let check_error label expected raw =
      match Eta_http.Core.Url.parse raw with
      | Ok _ -> Alcotest.failf "%s unexpectedly parsed" label
      | Error actual ->
          Alcotest.(check string)
            label expected
            (Eta_http.Core.Url.parse_error_to_string actual)
    in
    check_error "userinfo" "userinfo is not supported"
      "https://user:pass@example.test/";
    check_error "scheme" "unsupported URL scheme \"ftp\""
      "ftp://example.test/";
    check_error "port" "invalid URL port \"99999\""
      "https://example.test:99999/"

  let test_url_fragment_question_mark_not_query () =
    match
      Eta_http.Core.Url.parse "https://example.test/callback#token?secret=1"
    with
    | Error err ->
        Alcotest.failf "parse failed: %a" Eta_http.Core.Url.pp_parse_error err
    | Ok url ->
        Alcotest.(check (option string)) "query after # is not a URI query" None
          (Eta_http.Core.Url.query url);
        Alcotest.(check string)
          "origin-form must not include fragment-derived query" "/callback"
          (Eta_http.Core.Url.origin_form url)

  let test_url_ipv6_authority_restores_brackets () =
    let url = Eta_http.Core.Url.of_string "https://[::1]:8443/path" in
    Alcotest.(check string) "host unbracketed" "::1"
      (Eta_http.Core.Url.host url);
    Alcotest.(check string) "authority bracketed" "[::1]:8443"
      (Eta_http.Core.Url.authority url);
    let bytes = Bytes.create 64 in
    let len = Eta_http.Core.Url.blit_authority bytes ~pos:0 url in
    Alcotest.(check string) "raw authority" "[::1]:8443"
      (Bytes.sub_string bytes 0 len);
    (match
       Eta_http.H1.Write.to_string ~method_:"GET" ~url ~headers:[]
         ~body:Eta_http.H1.Write.Empty
     with
    | Error error -> Alcotest.fail (Eta_http.Error.to_string error)
    | Ok wire ->
        Alcotest.(check bool) "host header" true
          (contains wire "\r\nHost: [::1]:8443\r\n"));
    let no_port = Eta_http.Core.Url.of_string "https://[2001:db8::1]/" in
    Alcotest.(check string) "authority no port" "[2001:db8::1]"
      (Eta_http.Core.Url.authority no_port);
    let reg_name = Eta_http.Core.Url.of_string "https://example.com:8080/" in
    Alcotest.(check string) "reg-name authority" "example.com:8080"
      (Eta_http.Core.Url.authority reg_name)

  let test_idempotency_classifier () =
    let get =
      Eta_http.Request.make ~body:(Fixed [ Bytes.of_string "x" ]) "GET"
        "https://api.example.test/resource"
    in
    Alcotest.(check bool) "GET retryable" true
      (Eta_http.Idempotency.retryable get);
    let post =
      Eta_http.Request.make ~body:(Fixed [ Bytes.of_string "x" ]) "POST"
        "https://api.example.test/resource"
    in
    Alcotest.(check bool) "POST default" false
      (Eta_http.Idempotency.retryable post);
    let post_with_key = Eta_http.Idempotency.with_idempotency_key "k1" post in
    Alcotest.(check bool) "POST with key" true
      (Eta_http.Idempotency.retryable post_with_key);
    let one_shot =
      Eta_http.Request.make
        ~body:(Stream (Eta_http.Body.Stream.of_bytes [ Bytes.of_string "x" ]))
        "GET" "https://api.example.test/resource"
    in
    Alcotest.(check bool) "one-shot body" false
      (Eta_http.Idempotency.retryable one_shot)

  let test_retry_after_parser () =
    let seconds =
      Eta_http.Retry_policy.retry_after "5" |> Option.map Eta.Duration.to_ms
    in
    Alcotest.(check (option int)) "delta seconds" (Some 5000) seconds;
    Alcotest.(check (option int)) "signed seconds rejected" None
      (Eta_http.Retry_policy.retry_after "+5" |> Option.map Eta.Duration.to_ms);
    let http_date =
      Eta_http.Retry_policy.retry_after ~now_s:1445412475.0
        "Wed, 21 Oct 2015 07:28:00 GMT"
      |> Option.map Eta.Duration.to_ms
    in
    Alcotest.(check (option int)) "http date" (Some 5000) http_date

  let test_retry_policy_classification () =
    let policy =
      Eta_http.Retry_policy.make ~max_attempts:2
        ~schedule:(Eta.Schedule.spaced (Eta.Duration.ms 7))
        ~respect_retry_after:false ()
    in
    let request = Eta_http.Request.make "GET" "https://api.example.test/retry" in
    (match
       Eta_http.Retry_policy.classify_response policy ~request ~attempt:1
         (retry_response 503)
     with
    | Retry_after delay ->
        Alcotest.(check int) "status delay" 7 (Eta.Duration.to_ms delay)
    | Stop -> Alcotest.fail "retry stopped");
    let error =
      Eta_http.Error.make ~protocol:H1 ~method_:"GET"
        ~uri:"https://api.example.test/retry"
        (Connection_closed { during = Http_response })
    in
    match Eta_http.Retry_policy.classify_error policy ~request ~attempt:1 error with
    | Retry_after delay ->
        Alcotest.(check int) "error delay" 7 (Eta.Duration.to_ms delay)
    | Stop -> Alcotest.fail "error retry stopped"

  let test_retry_after_overflow_delta_seconds_is_ignored () =
    let huge = string_of_int ((max_int / 1000) + 1) in
    Alcotest.(check (option int))
      "overflow delta seconds" None
      (Eta_http.Retry_policy.retry_after huge |> Option.map Eta.Duration.to_ms)

  let test_retry_after_rejects_impossible_http_date () =
    let invalid = "Wed, 99 Jun 2026 99:99:99 GMT" in
    Alcotest.(check (option int))
      "invalid Retry-After date rejected" None
      (Option.map Eta.Duration.to_ms
         (Eta_http.Retry_policy.retry_after ~now_s:0.0 invalid))

  let http_date_of_epoch_s epoch_s =
    let tm = Unix.gmtime epoch_s in
    let weekdays =
      [| "Sun"; "Mon"; "Tue"; "Wed"; "Thu"; "Fri"; "Sat" |]
    in
    let months =
      [|
        "Jan";
        "Feb";
        "Mar";
        "Apr";
        "May";
        "Jun";
        "Jul";
        "Aug";
        "Sep";
        "Oct";
        "Nov";
        "Dec";
      |]
    in
    Printf.sprintf "%s, %02d %s %04d %02d:%02d:%02d GMT"
      weekdays.(tm.Unix.tm_wday) tm.Unix.tm_mday months.(tm.Unix.tm_mon)
      (tm.Unix.tm_year + 1900) tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

  let retry_after_delay_ms = function
    | Eta_http.Retry_policy.Retry_after delay -> Eta.Duration.to_ms delay
    | Stop -> Alcotest.fail "retry stopped"

  let test_retry_after_absolute_date_uses_clock () =
    let policy =
      Eta_http.Retry_policy.make ~max_attempts:2
        ~schedule:(Eta.Schedule.spaced (Eta.Duration.ms 999))
        ()
    in
    let request = Eta_http.Request.make "GET" "https://api.example.test/retry" in
    let now_s = 1_445_412_475.0 in
    let classify headers =
      Eta_http.Retry_policy.classify_response policy ~now_s ~request ~attempt:1
        (retry_response ~headers 503)
      |> retry_after_delay_ms
    in
    Alcotest.(check int) "absolute future date" 5_000
      (classify [ "Retry-After", http_date_of_epoch_s (now_s +. 5.0) ]);
    Alcotest.(check int) "numeric seconds" 5_000
      (classify [ "Retry-After", "5" ]);
    Alcotest.(check int) "past date clamps" 0
      (classify [ "Retry-After", http_date_of_epoch_s (now_s -. 5.0) ])

  let test_retry_policy_overflow_retry_after_falls_back_to_schedule () =
    let policy =
      Eta_http.Retry_policy.make ~max_attempts:2
        ~schedule:(Eta.Schedule.spaced (Eta.Duration.ms 7))
        ()
    in
    let request = Eta_http.Request.make "GET" "https://api.example.test/retry" in
    let huge = string_of_int ((max_int / 1000) + 1) in
    match
      Eta_http.Retry_policy.classify_response policy ~request ~attempt:1
        (retry_response ~headers:[ "Retry-After", huge ] 503)
    with
    | Retry_after delay ->
        Alcotest.(check int) "fallback delay" 7 (Eta.Duration.to_ms delay)
    | Stop -> Alcotest.fail "retry stopped"

  let test_retry_policy_overflow_retry_after_date_falls_back_to_schedule () =
    let policy =
      Eta_http.Retry_policy.make ~max_attempts:2
        ~schedule:(Eta.Schedule.spaced (Eta.Duration.ms 7))
        ()
    in
    let request = Eta_http.Request.make "GET" "https://api.example.test/retry" in
    match
      Eta_http.Retry_policy.classify_response policy ~now_s:0.0 ~request
        ~attempt:1
        (retry_response
           ~headers:[ "Retry-After", "Wed, 01 Jan 999999999 00:00:00 GMT" ]
           503)
    with
    | Retry_after delay ->
        Alcotest.(check int) "fallback delay" 7 (Eta.Duration.to_ms delay)
    | Stop -> Alcotest.fail "retry stopped"

  let test_retry_policy_rejects_invalid_max_attempts () =
    Alcotest.check_raises "max_attempts must be positive"
      (Invalid_argument "Eta_http.Retry_policy.make: max_attempts must be > 0")
      (fun () ->
        ignore
          (Eta_http.Retry_policy.make ~max_attempts:0 ()
            : Eta_http.Retry_policy.t))

  let test_retry_policy_max_attempts_one_does_not_retry () =
    let policy =
      Eta_http.Retry_policy.make ~max_attempts:1
        ~schedule:(Eta.Schedule.spaced (Eta.Duration.ms 7))
        ()
    in
    let request = Eta_http.Request.make "GET" "https://api.example.test/retry" in
    match
      Eta_http.Retry_policy.classify_response policy ~request ~attempt:1
        (retry_response 503)
    with
    | Stop -> ()
    | Retry_after _ -> Alcotest.fail "retry should stop after one attempt"

  let otlp_retry_status = function
    | 429 | 502 | 503 | 504 -> true
    | _ -> false

  let test_retry_policy_custom_status_classifier () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let request = Eta_http.Request.make "GET" "https://api.example.test/retry" in
    Alcotest.(check bool) "default retries 408" true
      (Eta_http.Retry_policy.default_retry_status 408);
    Alcotest.(check bool) "otlp rejects 408" false (otlp_retry_status 408);
    let policy =
      Eta_http.Retry_policy.make ~max_attempts:3
        ~schedule:(Eta.Schedule.spaced Eta.Duration.zero)
        ~retry_status:otlp_retry_status ()
    in
    let assert_status_decision status expected =
      let response = retry_response status in
      let actual =
        match
          Eta_http.Retry_policy.classify_response policy ~request ~attempt:1
            response
        with
        | Retry_after _ -> true
        | Stop -> false
      in
      Alcotest.(check bool)
        (Printf.sprintf "retry status %d" status)
        expected actual
    in
    assert_status_decision 400 false;
    assert_status_decision 408 false;
    assert_status_decision 429 true;
    assert_status_decision 502 true;
    assert_status_decision 503 true;
    assert_status_decision 504 true;
    let attempts, client =
      retry_client
        [|
          (fun () -> retry_response ~headers:[ "Retry-After", "0" ] 408);
          (fun () -> retry_response 200);
        |]
    in
    let response =
      B.run rt (Eta_http.request_with_retry ~policy client request) |> expect_ok
    in
    Alcotest.(check int) "408 status" 408 response.status;
    Alcotest.(check int) "408 attempts" 1 !attempts;
    let attempts, client =
      retry_client
        [|
          (fun () -> retry_response ~headers:[ "Retry-After", "0" ] 429);
          (fun () -> retry_response 200);
        |]
    in
    let response =
      B.run rt (Eta_http.request_with_retry ~policy client request) |> expect_ok
    in
    Alcotest.(check int) "429 final status" 200 response.status;
    Alcotest.(check int) "429 attempts" 2 !attempts

  let test_retry_always_still_requires_replayable_body () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let attempts, client =
      retry_client
        [|
          (fun () -> retry_response ~headers:[ "Retry-After", "0" ] 503);
          (fun () -> retry_response 200);
        |]
    in
    let request =
      Eta_http.Request.make
        ~body:(Stream (Eta_http.Body.Stream.of_bytes [ Bytes.of_string "x" ]))
        "POST" "https://api.example.test/retry"
    in
    let policy =
      Eta_http.Retry_policy.always ~max_attempts:3
        ~schedule:(Eta.Schedule.spaced Eta.Duration.zero)
        ()
    in
    let response =
      B.run rt (Eta_http.request_with_retry ~policy client request) |> expect_ok
    in
    Alcotest.(check int) "status" 503 response.status;
    Alcotest.(check int) "attempts" 1 !attempts

  let span_attr key span = List.assoc_opt key span.Eta.Tracer.attrs

  let find_span name tracer =
    match
      List.filter
        (fun span -> String.equal span.Eta.Tracer.name name)
        (Eta.Tracer.dump tracer)
    with
    | span :: _ -> span
    | [] -> Alcotest.failf "missing span %s" name

  let observability_client ?(protocol = Eta_http.Client.H1) request =
    Eta_http.Client.make_custom ~protocol ~request
      ~stats:(fun () ->
        Eta.Effect.pure
          {
            Eta_http.Client.protocol;
            active = 2;
            idle = 3;
            capacity = 5;
            opened = 8;
            released = 6;
          })
      ~shutdown:(fun () -> Eta.Effect.unit)

  let expect_typed_failure exit predicate =
    match exit with
    | Eta.Exit.Error (Eta.Cause.Fail error) when predicate error -> ()
    | Eta.Exit.Error cause ->
        Alcotest.failf "unexpected failure: %a"
          (Eta.Cause.pp Eta_http.Error.pp)
          cause
    | Eta.Exit.Ok _ -> Alcotest.fail "expected typed failure"

  let test_observability_success_get_semconv () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let client =
      observability_client (fun _ -> Eta.Effect.pure (retry_response 200))
    in
    let request =
      Eta_http.Request.make "get" "https://api.example.test:8443/a?b=c"
    in
    let response =
      B.run rt (Eta_http.Observability.Tracer.request client request)
      |> expect_ok
    in
    Alcotest.(check int) "status" 200 response.status;
    let span = find_span "HTTP GET" tracer in
    Alcotest.(check (option string)) "method" (Some "GET")
      (span_attr "http.request.method" span);
    Alcotest.(check (option string)) "url"
      (Some "https://api.example.test:8443/a?<redacted>")
      (span_attr "url.full" span);
    Alcotest.(check (option string)) "server" (Some "api.example.test")
      (span_attr "server.address" span);
    Alcotest.(check (option string)) "port" (Some "8443")
      (span_attr "server.port" span);
    Alcotest.(check (option string)) "protocol" (Some "1.1")
      (span_attr "network.protocol.version" span);
    Alcotest.(check (option string)) "status attr" (Some "200")
      (span_attr "http.response.status_code" span)

  let test_observability_redacts_url_query_by_default () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let client =
      observability_client (fun _ -> Eta.Effect.pure (retry_response 200))
    in
    let request =
      Eta_http.Request.make "GET"
        "https://api.example.test/private?token=secret&email=a@example.test#frag"
    in
    ignore
      (B.run rt (Eta_http.Observability.Tracer.request client request)
      |> expect_ok);
    let span = find_span "HTTP GET" tracer in
    Alcotest.(check (option string)) "redacted url"
      (Some "https://api.example.test/private?<redacted>#frag")
      (span_attr "url.full" span)

  let test_observability_can_emit_raw_url_full () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let client =
      observability_client (fun _ -> Eta.Effect.pure (retry_response 200))
    in
    let uri = "https://api.example.test/private?token=secret#frag" in
    let request = Eta_http.Request.make "GET" uri in
    ignore
      (B.run rt
         (Eta_http.Observability.Tracer.request ~emit_url_full:true client request)
      |> expect_ok);
    let span = find_span "HTTP GET" tracer in
    Alcotest.(check (option string)) "raw url" (Some uri)
      (span_attr "url.full" span)

  let test_observability_dns_error_semconv () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let error =
      Eta_http.Error.make ~method_:"GET" ~uri:"https://missing.example.test/"
        (Eta_http.Error.Dns_error
           { host = "missing.example.test"; message = "no such host" })
    in
    let client = observability_client (fun _ -> Eta.Effect.fail error) in
    let request = Eta_http.Request.make "GET" "https://missing.example.test/" in
    expect_typed_failure
      (B.run rt (Eta_http.Observability.Tracer.request client request))
      (fun err ->
        match err.Eta_http.Error.kind with
        | Eta_http.Error.Dns_error _ -> true
        | _ -> false);
    let span = find_span "HTTP GET" tracer in
    Alcotest.(check (option string)) "error type" (Some "dns_error")
      (span_attr "error.type" span)

  let test_observability_tls_error_semconv () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let error =
      Eta_http.Error.make ~method_:"GET" ~uri:"https://expired.example.test/"
        (Eta_http.Error.Tls_handshake_error
           {
             stage = Eta_http.Error.Tls_handshake;
             message = "certificate expired";
           })
    in
    let client = observability_client (fun _ -> Eta.Effect.fail error) in
    let request = Eta_http.Request.make "GET" "https://expired.example.test/" in
    expect_typed_failure
      (B.run rt (Eta_http.Observability.Tracer.request client request))
      (fun err ->
        match err.Eta_http.Error.kind with
        | Eta_http.Error.Tls_handshake_error _ -> true
        | _ -> false);
    let span = find_span "HTTP GET" tracer in
    Alcotest.(check (option string)) "error type" (Some "tls_handshake_error")
      (span_attr "error.type" span)

  let test_observability_retry_success_spans () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let attempts, client =
      retry_client
        [|
          (fun () -> retry_response ~headers:[ "Retry-After", "0" ] 503);
          (fun () -> retry_response 200);
        |]
    in
    let request = Eta_http.Request.make "GET" "https://api.example.test/retry" in
    let response =
      B.run rt (Eta_http.Observability.Tracer.request_with_retry client request)
      |> expect_ok
    in
    Alcotest.(check int) "status" 200 response.status;
    Alcotest.(check int) "attempts" 2 !attempts;
    let spans = Eta.Tracer.dump tracer in
    Alcotest.(check bool) "parent span" true
      (List.exists
         (fun span -> String.equal span.Eta.Tracer.name "HTTP GET retry")
         spans);
    Alcotest.(check bool) "attempt span" true
      (List.exists
         (fun span ->
           String.equal span.Eta.Tracer.name "HTTP GET"
           && Option.equal String.equal
                (span_attr "http.request.resend_count" span)
                (Some "1"))
         spans)

  let test_observability_redirect_semconv () =
    let location = "https://api.example.test/next?token=secret#frag" in
    let attrs = Eta_http.Observability.Semconv.redirect_attrs ~location () in
    Alcotest.(check (option string)) "redacted location"
      (Some "https://api.example.test/next?<redacted>#<redacted>")
      (List.assoc_opt "http.response.header.location" attrs)

  let test_observability_redirect_semconv_can_emit_raw () =
    let location = "https://api.example.test/next?token=secret#frag" in
    let attrs =
      Eta_http.Observability.Semconv.redirect_attrs ~emit_location_full:true
        ~location ()
    in
    Alcotest.(check (option string)) "raw location" (Some location)
      (List.assoc_opt "http.response.header.location" attrs)

  let test_observability_h2_protocol_attrs () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let client =
      observability_client ~protocol:Eta_http.Client.H2 (fun _ ->
          Eta.Effect.pure (retry_response 200))
    in
    let request = Eta_http.Request.make "GET" "https://api.example.test/h2" in
    ignore
      (B.run rt
         (Eta_http.Observability.Tracer.request ~protocol:Eta_http.Client.H2
            client request)
      |> expect_ok);
    let span = find_span "HTTP GET" tracer in
    Alcotest.(check (option string)) "h2" (Some "2")
      (span_attr "network.protocol.version" span)

  let test_observability_recursion_disabled () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let client =
      observability_client (fun _ -> Eta.Effect.pure (retry_response 200))
    in
    let request =
      Eta_http.Request.make "POST" "https://collector.example.test/v1/traces"
    in
    ignore
      (B.run rt
         (Eta_http.Observability.Tracer.request ~enabled:false client request)
      |> expect_ok);
    Alcotest.(check int) "spans" 0 (List.length (Eta.Tracer.dump tracer))

  let test_observability_recursion_disabled_suppresses_inner_spans () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let client =
      observability_client (fun _ ->
          Eta.Effect.named "eta-http.internal"
            (Eta.Effect.pure (retry_response 200)))
    in
    let request =
      Eta_http.Request.make "POST" "https://collector.example.test/v1/traces"
    in
    ignore
      (B.run rt
         (Eta_http.Observability.Tracer.request ~enabled:false client request)
      |> expect_ok);
    Alcotest.(check int) "spans" 0 (List.length (Eta.Tracer.dump tracer))

  let test_observability_pool_stats_meter () =
    B.with_meter_runtime @@ fun _ctx rt meter ->
    let client =
      observability_client (fun _ -> Eta.Effect.pure (retry_response 200))
    in
    B.run rt (Eta_http.Observability.Meter.record_client_stats client)
    |> expect_ok;
    let names = List.map (fun point -> point.Eta.Meter.name) (Eta.Meter.dump meter) in
    Alcotest.(check bool) "active metric" true
      (List.mem "eta_http.client.connections.active" names)

  let test_retry_succeeds_on_third_attempt () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let released = ref 0 in
    let attempts, client =
      retry_client
        [|
          (fun () ->
            retry_response ~headers:[ "Retry-After", "0" ]
              ~release:(fun () ->
                incr released;
                Eta.Effect.unit)
              503);
          (fun () ->
            retry_response ~headers:[ "Retry-After", "0" ]
              ~release:(fun () ->
                incr released;
                Eta.Effect.unit)
              503);
          (fun () -> retry_response 200);
        |]
    in
    let request = Eta_http.Request.make "GET" "https://api.example.test/retry" in
    let response =
      B.run rt (Eta_http.request_with_retry client request) |> expect_ok
    in
    Alcotest.(check int) "status" 200 response.status;
    Alcotest.(check int) "attempts" 3 !attempts;
    Alcotest.(check int) "discard failed bodies" 2 !released

  let test_retry_non_idempotent_requires_opt_in () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let post =
      Eta_http.Request.make ~body:(Fixed [ Bytes.of_string "payload" ]) "POST"
        "https://api.example.test/retry"
    in
    let attempts, client =
      retry_client
        [|
          (fun () -> retry_response ~headers:[ "Retry-After", "0" ] 503);
          (fun () -> retry_response 200);
        |]
    in
    let response =
      B.run rt (Eta_http.request_with_retry client post) |> expect_ok
    in
    Alcotest.(check int) "default status" 503 response.status;
    Alcotest.(check int) "default attempts" 1 !attempts;
    let attempts, client =
      retry_client
        [|
          (fun () -> retry_response ~headers:[ "Retry-After", "0" ] 503);
          (fun () -> retry_response 200);
        |]
    in
    let response =
      B.run rt
        (Eta_http.request_with_retry client
           (Eta_http.Idempotency.with_idempotency_key "key-1" post))
      |> expect_ok
    in
    Alcotest.(check int) "key status" 200 response.status;
    Alcotest.(check int) "key attempts" 2 !attempts

  let test_ws_accept_key_vector () =
    Alcotest.(check string)
      "accept" "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
      (Eta_http.Ws.Codec.accept_key "dGhlIHNhbXBsZSBub25jZQ==")

  let test_ws_codec_masked_text_roundtrip () =
    let mask = Bytes.of_string "\x37\xfa\x21\x3d" in
    let frame : Eta_http.Ws.Codec.frame =
      { fin = true; opcode = Eta_http.Ws.Codec.Text; payload = Bytes.of_string "Hello" }
    in
    let encoded = Eta_http.Ws.Codec.encode ~mask frame in
    match Eta_http.Ws.Codec.decode ~masked:true encoded with
    | Ok ({ opcode = Eta_http.Ws.Codec.Text; payload; _ }, consumed) ->
        Alcotest.(check int) "consumed" (Bytes.length encoded) consumed;
        Alcotest.(check string) "payload" "Hello" (Bytes.to_string payload)
    | Ok _ -> Alcotest.fail "decoded unexpected frame"
    | Error error ->
        Alcotest.failf "masked frame failed: %s"
          (Eta_http.Ws.Codec.parse_error_to_string error)

  let test_ws_codec_rejects_one_byte_close_payload () =
    let frame = Bytes.of_string "\x88\x01\000" in
    match Eta_http.Ws.Codec.decode frame with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "one-byte close payload decoded successfully"

  let test_ws_codec_rejects_encoded_one_byte_close_payload () =
    Alcotest.check_raises "one-byte close payload rejected"
      (Invalid_argument
         "WebSocket close frame payload must be empty or at least two bytes")
      (fun () ->
        let frame : Eta_http.Ws.Codec.frame =
          {
            fin = true;
            opcode = Eta_http.Ws.Codec.Close;
            payload = Bytes.of_string "\000";
          }
        in
        ignore (Eta_http.Ws.Codec.encode frame : bytes))

  let ws_close_status_payload code =
    let payload = Bytes.create 2 in
    Bytes.set payload 0 (Char.chr ((code lsr 8) land 0xff));
    Bytes.set payload 1 (Char.chr (code land 0xff));
    payload

  let ws_raw_close_frame code =
    let frame = Bytes.create 4 in
    Bytes.set frame 0 (Char.chr 0x88);
    Bytes.set frame 1 (Char.chr 0x02);
    Bytes.blit (ws_close_status_payload code) 0 frame 2 2;
    frame

  let test_ws_codec_rejects_invalid_close_status_codes () =
    List.iter
      (fun code ->
        match Eta_http.Ws.Codec.decode (ws_raw_close_frame code) with
        | Error _ -> ()
        | Ok _ -> Alcotest.failf "accepted invalid close status code %d" code)
      [ 999; 1004; 1005; 1006; 1015; 5000 ]

  let test_ws_codec_encoder_rejects_invalid_close_status_code () =
    let frame : Eta_http.Ws.Codec.frame =
      {
        fin = true;
        opcode = Eta_http.Ws.Codec.Close;
        payload = ws_close_status_payload 1005;
      }
    in
    match Eta_http.Ws.Codec.encode frame with
    | _ -> Alcotest.fail "encoded invalid close status code 1005"
    | exception Invalid_argument message ->
        Alcotest.(check bool)
          "mentions close status" true
          (contains message "close")

  let test_ws_random_material_does_not_use_stdlib_random () =
    let codec = read_file (find_ws_source "codec.ml") in
    let client = read_file (find_ws_source "ws_client.ml") in
    Alcotest.(check bool) "codec avoids Stdlib.Random" false
      (contains codec "Stdlib.Random");
    Alcotest.(check bool) "client avoids Stdlib.Random" false
      (contains client "Stdlib.Random")

  let test_ws_accept_key_does_not_own_sha1 () =
    let codec = read_file (find_ws_source "codec.ml") in
    Alcotest.(check bool) "codec does not define SHA-1" false
      (contains codec "let sha1");
    Alcotest.(check bool) "codec does not implement SHA-1 rounds" false
      (contains codec "let open Int32")

  let h2_frame_header ~length ~frame_type ~flags ~stream_id =
    Eta_http.H2.Frame.header ~length
      ~frame_type:(Eta_http.H2.Frame.Other frame_type)
      ~flags ~stream_id

  let h2_payload = Eta_http.H2.Frame.payload
  let h2_goaway_no_error = Eta_http.H2.Frame.goaway_no_error
  let h2_settings_frame = h2_frame_header ~length:0 ~frame_type:0x4 ~flags:0 ~stream_id:0

  let h2_observe_security data =
    let security = Eta_http.H2.Security.create () in
    let bs = Bigstringaf.of_string ~off:0 ~len:(String.length data) data in
    Eta_http.H2.Security.observe security bs ~off:0 ~len:(String.length data)

  let h2_permit label = function
    | Ok permit -> permit
    | Error () -> Alcotest.failf "%s rejected unexpectedly" label

  let test_h2_admission_counts_cancelled_until_release () =
    let admission = Eta_http.H2.Admission.create ~max_concurrent:2 in
    let first = h2_permit "first" (Eta_http.H2.Admission.try_acquire admission) in
    let second =
      h2_permit "second" (Eta_http.H2.Admission.try_acquire admission)
    in
    Alcotest.(check int) "first stream id" 1
      (Eta_http.H2.Admission.stream_id first);
    Alcotest.(check int) "second stream id" 3
      (Eta_http.H2.Admission.stream_id second);
    (match Eta_http.H2.Admission.try_acquire admission with
    | Ok _ -> Alcotest.fail "third stream should be rejected at limit"
    | Error () -> ());
    Eta_http.H2.Admission.mark_remote_reset admission first;
    let reset_stats = Eta_http.H2.Admission.stats admission in
    Alcotest.(check int) "active after remote reset" 1 reset_stats.active;
    Alcotest.(check int) "cancelled after remote reset" 1
      reset_stats.cancelled;
    Alcotest.(check int) "cancelled counts as inflight" 2
      reset_stats.inflight;
    (match Eta_http.H2.Admission.try_acquire admission with
    | Ok _ -> Alcotest.fail "cancelled stream should still occupy admission"
    | Error () -> ());
    Alcotest.(check bool) "remote reset release does not queue RST" true
      (Eta_http.H2.Admission.release admission first
      = Eta_http.H2.Admission.No_rst);
    let third = h2_permit "third" (Eta_http.H2.Admission.try_acquire admission) in
    Alcotest.(check int) "third stream id" 5
      (Eta_http.H2.Admission.stream_id third);
    Alcotest.(check bool) "active release queues RST" true
      (Eta_http.H2.Admission.release admission second
      = Eta_http.H2.Admission.Queue_rst);
    Alcotest.(check bool) "release is idempotent" true
      (Eta_http.H2.Admission.release admission second
      = Eta_http.H2.Admission.No_rst);
    Alcotest.(check bool) "third active release queues RST" true
      (Eta_http.H2.Admission.release admission third
      = Eta_http.H2.Admission.Queue_rst);
    let stats = Eta_http.H2.Admission.stats admission in
    Alcotest.(check int) "active final" 0 stats.active;
    Alcotest.(check int) "cancelled final" 0 stats.cancelled;
    Alcotest.(check int) "opened" 3 stats.opened;
    Alcotest.(check int) "completed" 3 stats.completed;
    Alcotest.(check int) "local resets" 2 stats.local_resets;
    Alcotest.(check int) "remote resets" 1 stats.remote_resets;
    Alcotest.(check int) "rejected" 2 stats.admission_rejected;
    Alcotest.(check int) "max inflight" 2 stats.max_inflight

  let h2_stream label = function
    | Ok stream -> stream
    | Error () -> Alcotest.failf "%s rejected unexpectedly" label

  let test_h2_stream_state_release_decisions () =
    let state = Eta_http.H2.Stream_state.create ~max_concurrent:2 in
    let first =
      h2_stream "first" (Eta_http.H2.Stream_state.open_stream state ~tag:11)
    in
    let second =
      h2_stream "second" (Eta_http.H2.Stream_state.open_stream state ~tag:12)
    in
    Alcotest.(check bool) "server stream id rejected" false
      (Eta_http.H2.Stream_state.is_client_stream_id 2);
    Alcotest.(check int) "first stream id" 1
      (Eta_http.H2.Stream_state.id first);
    Alcotest.(check bool) "first client stream id" true
      (Eta_http.H2.Stream_state.is_client_stream_id
         (Eta_http.H2.Stream_state.id first));
    Alcotest.(check int) "second stream id" 3
      (Eta_http.H2.Stream_state.id second);
    Alcotest.(check int) "tag" 11 (Eta_http.H2.Stream_state.tag first);
    (match Eta_http.H2.Stream_state.open_stream state ~tag:13 with
    | Ok _ -> Alcotest.fail "third stream should be rejected at limit"
    | Error () -> ());
    Eta_http.H2.Stream_state.mark_remote_reset state
      (Eta_http.H2.Stream_state.id first);
    Alcotest.(check bool) "first remote reset" true
      (Eta_http.H2.Stream_state.status first
      = Eta_http.H2.Stream_state.Remote_reset);
    let reset_stats = Eta_http.H2.Stream_state.stats state in
    Alcotest.(check int) "active after reset" 1 reset_stats.active;
    Alcotest.(check int) "cancelled after reset" 1 reset_stats.cancelled;
    Alcotest.(check int) "cancelled still inflight" 2 reset_stats.inflight;
    Alcotest.(check int) "live after reset" 2 reset_stats.live;
    (match Eta_http.H2.Stream_state.open_stream state ~tag:14 with
    | Ok _ -> Alcotest.fail "cancelled stream should still occupy admission"
    | Error () -> ());
    Alcotest.(check bool) "remote reset release does not queue RST" true
      (Eta_http.H2.Stream_state.release state first
      = Eta_http.H2.Stream_state.No_rst);
    Alcotest.(check bool) "release idempotent" true
      (Eta_http.H2.Stream_state.release state first
      = Eta_http.H2.Stream_state.No_rst);
    let third =
      h2_stream "third" (Eta_http.H2.Stream_state.open_stream state ~tag:13)
    in
    Alcotest.(check int) "third stream id" 5
      (Eta_http.H2.Stream_state.id third);
    Eta_http.H2.Stream_state.mark_complete state second;
    Alcotest.(check bool) "second complete" true
      (Eta_http.H2.Stream_state.status second
      = Eta_http.H2.Stream_state.Complete);
    Alcotest.(check bool) "complete release does not queue RST" true
      (Eta_http.H2.Stream_state.release state second
      = Eta_http.H2.Stream_state.No_rst);
    Alcotest.(check bool) "active release queues RST" true
      (Eta_http.H2.Stream_state.release state third
      = Eta_http.H2.Stream_state.Queue_rst);
    let stats = Eta_http.H2.Stream_state.stats state in
    Alcotest.(check int) "active final" 0 stats.active;
    Alcotest.(check int) "cancelled final" 0 stats.cancelled;
    Alcotest.(check int) "live final" 0 stats.live;
    Alcotest.(check int) "opened" 3 stats.opened;
    Alcotest.(check int) "completed" 3 stats.completed;
    Alcotest.(check int) "local resets" 1 stats.local_resets;
    Alcotest.(check int) "remote resets" 1 stats.remote_resets;
    Alcotest.(check int) "rejected" 2 stats.admission_rejected;
    Alcotest.(check int) "max inflight" 2 stats.max_inflight

  let test_h2_stream_state_close_releases_live_state () =
    let state = Eta_http.H2.Stream_state.create ~max_concurrent:2 in
    let first =
      h2_stream "first" (Eta_http.H2.Stream_state.open_stream state ~tag:1)
    in
    let second =
      h2_stream "second" (Eta_http.H2.Stream_state.open_stream state ~tag:2)
    in
    Eta_http.H2.Stream_state.mark_remote_reset state
      (Eta_http.H2.Stream_state.id first);
    Eta_http.H2.Stream_state.close state;
    Alcotest.(check bool) "first released" true
      (Eta_http.H2.Stream_state.status first = Eta_http.H2.Stream_state.Released);
    Alcotest.(check bool) "second released" true
      (Eta_http.H2.Stream_state.status second
      = Eta_http.H2.Stream_state.Released);
    (match Eta_http.H2.Stream_state.open_stream state ~tag:3 with
    | Ok _ -> Alcotest.fail "closed state should reject new streams"
    | Error () -> ());
    let stats = Eta_http.H2.Stream_state.stats state in
    Alcotest.(check int) "active closed" 0 stats.active;
    Alcotest.(check int) "cancelled closed" 0 stats.cancelled;
    Alcotest.(check int) "live closed" 0 stats.live

  let test_h2_frame_parse_header () =
    let base =
      Eta_http.H2.Frame.header ~length:0x010203
        ~frame_type:(Eta_http.H2.Frame.Other 0xfe)
        ~flags:0xa5 ~stream_id:0x01020304
    in
    let raw = Bytes.of_string base in
    Bytes.set raw 5 (Char.chr (Char.code (Bytes.get raw 5) lor 0x80));
    let data = Bytes.unsafe_to_string raw in
    let check label envelope =
      Alcotest.(check int) (label ^ " length") 0x010203
        envelope.Eta_http.H2.Frame.length;
      Alcotest.(check int) (label ^ " type") 0xfe envelope.frame_type;
      Alcotest.(check int) (label ^ " flags") 0xa5 envelope.flags;
      Alcotest.(check int) (label ^ " stream_id") 0x01020304
        envelope.stream_id
    in
    check "string" (Eta_http.H2.Frame.parse_header_string data ~off:0);
    check "bytes" (Eta_http.H2.Frame.parse_header_bytes raw ~off:0);
    let buffer = Buffer.create 16 in
    Buffer.add_string buffer data;
    check "buffer" (Eta_http.H2.Frame.parse_header_buffer buffer ~off:0)

  let test_h2_frame_uint32_rejects_overflow () =
    Alcotest.check_raises "uint32 overflow"
      (Invalid_argument "Eta_http.H2.Frame.uint32: value outside uint32")
      (fun () -> ignore (Eta_http.H2.Frame.uint32 (Int.shift_left 1 32)))

  let test_h2_writer_preserves_iovec_slices () =
    let buffer = Bigstringaf.of_string ~off:0 ~len:10 "0123456789" in
    let iovecs = [ { H2.IOVec.buffer; off = 2; len = 4 } ] in
    match Eta_http_eio.H2.Writer.cstructs_of_iovecs iovecs with
    | [ slice ] ->
        Alcotest.(check int) "slice len" 4 (Cstruct.length slice);
        Alcotest.(check string) "slice bytes" "2345" (Cstruct.to_string slice)
    | _ -> Alcotest.fail "expected one cstruct slice"

  let test_h2_security_hpack_block_cap () =
    let frame =
      h2_frame_header ~length:(300 * 1024) ~frame_type:0x1 ~flags:0x4
        ~stream_id:1
    in
    match h2_observe_security frame with
    | Some (Eta_http.Error.Hpack_decode_overflow { decoded_bytes; limit_bytes }) ->
        Alcotest.(check int) "decoded" (300 * 1024) decoded_bytes;
        Alcotest.(check int) "limit" (256 * 1024) limit_bytes
    | Some kind ->
        Alcotest.failf "unexpected security error: %s"
          (Eta_http.Error.kind_name kind)
    | None -> Alcotest.fail "hpack block cap was not detected"

  let test_h2_security_continuation_cap () =
    let data =
      h2_frame_header ~length:(40 * 1024) ~frame_type:0x1 ~flags:0
        ~stream_id:1
      ^ h2_payload (40 * 1024)
      ^ h2_frame_header ~length:(30 * 1024) ~frame_type:0x9 ~flags:0x4
          ~stream_id:1
    in
    match h2_observe_security data with
    | Some
        (Eta_http.Error.Continuation_flood
          { accumulated_bytes; limit_bytes; frames }) ->
        Alcotest.(check int) "accumulated" (70 * 1024) accumulated_bytes;
        Alcotest.(check int) "limit" (64 * 1024) limit_bytes;
        Alcotest.(check int) "frames" 2 frames
    | Some kind ->
        Alcotest.failf "unexpected security error: %s"
          (Eta_http.Error.kind_name kind)
    | None -> Alcotest.fail "continuation cap was not detected"

  let test_h2_security_rejects_oversized_initial_headers_fragment () =
    let config =
      {
        Eta_http.H2.Security.default_config with
        max_hpack_block_bytes = 1024;
        max_continuation_accumulator_bytes = 16;
      }
    in
    let security = Eta_http.H2.Security.create ~config () in
    let frame =
      Eta_http.H2.Frame.header ~length:17
        ~frame_type:Eta_http.H2.Frame.Headers ~flags:0 ~stream_id:1
    in
    let bs = Bigstringaf.of_string ~off:0 ~len:(String.length frame) frame in
    match
      Eta_http.H2.Security.observe security bs ~off:0 ~len:(String.length frame)
    with
    | Some
        (Eta_http.Error.Continuation_flood
          { accumulated_bytes; limit_bytes; _ }) ->
        Alcotest.(check int) "accumulated" 17 accumulated_bytes;
        Alcotest.(check int) "limit" 16 limit_bytes
    | Some kind ->
        Alcotest.failf "unexpected error: %s" (Eta_http.Error.kind_name kind)
    | None -> Alcotest.fail "oversized initial HEADERS fragment was accepted"

  let test_h2_security_rejects_oversized_push_promise_fragment () =
    let config =
      {
        Eta_http.H2.Security.default_config with
        max_hpack_block_bytes = 16;
        max_continuation_accumulator_bytes = 16;
      }
    in
    let security = Eta_http.H2.Security.create ~config () in
    let payload_len = 4 + 17 in
    let frame =
      Eta_http.H2.Frame.header ~length:payload_len
        ~frame_type:Eta_http.H2.Frame.Push_promise ~flags:0x4 ~stream_id:1
      ^ Eta_http.H2.Frame.uint32 2
      ^ String.make 17 '\000'
    in
    let bs = Bigstringaf.of_string ~off:0 ~len:(String.length frame) frame in
    match
      Eta_http.H2.Security.observe security bs ~off:0 ~len:(String.length frame)
    with
    | Some
        (Eta_http.Error.Hpack_decode_overflow { decoded_bytes; limit_bytes }) ->
        Alcotest.(check int) "decoded" payload_len decoded_bytes;
        Alcotest.(check int) "limit" 16 limit_bytes
    | Some kind ->
        Alcotest.failf "unexpected error: %s" (Eta_http.Error.kind_name kind)
    | None -> Alcotest.fail "oversized PUSH_PROMISE fragment was accepted"

  let test_h2_security_goaway_churn () =
    let data =
      h2_goaway_no_error ~last_stream_id:1
      ^ h2_goaway_no_error ~last_stream_id:1
    in
    match h2_observe_security data with
    | Some
        (Eta_http.Error.Connection_closed
          { during = Eta_http.Error.Http_response }) ->
        ()
    | Some kind ->
        Alcotest.failf "unexpected security error: %s"
          (Eta_http.Error.kind_name kind)
    | None -> Alcotest.fail "GOAWAY churn was not detected"

  let test_h2_security_settings_churn () =
    let data = String.concat "" (List.init 11 (fun _ -> h2_settings_frame)) in
    match h2_observe_security data with
    | Some (Eta_http.Error.Settings_churn_rate_exceeded { observed_rate_hz; limit_hz }) ->
        Alcotest.(check int) "observed" 11 observed_rate_hz;
        Alcotest.(check int) "limit" 10 limit_hz
    | Some kind ->
        Alcotest.failf "unexpected security error: %s"
          (Eta_http.Error.kind_name kind)
    | None -> Alcotest.fail "settings churn was not detected"

  let test_h2_security_rst_churn () =
    let frame =
      h2_frame_header ~length:4 ~frame_type:0x3 ~flags:0 ~stream_id:1
      ^ h2_uint32 8
    in
    let data = String.concat "" (List.init 101 (fun _ -> frame)) in
    match h2_observe_security data with
    | Some
        (Eta_http.Error.Rst_rate_exceeded
          { observed_per_second; limit_per_second }) ->
        Alcotest.(check int) "observed" 101 observed_per_second;
        Alcotest.(check int) "limit" 100 limit_per_second
    | Some kind ->
        Alcotest.failf "unexpected security error: %s"
          (Eta_http.Error.kind_name kind)
    | None -> Alcotest.fail "RST churn was not detected"

  let test_h2_security_ping_churn () =
    let frame =
      h2_frame_header ~length:8 ~frame_type:0x6 ~flags:0 ~stream_id:0
      ^ String.make 8 '\000'
    in
    let data = String.concat "" (List.init 101 (fun _ -> frame)) in
    match h2_observe_security data with
    | Some
        (Eta_http.Error.Ping_rate_exceeded { observed_rate_hz; limit_hz }) ->
        Alcotest.(check int) "observed" 101 observed_rate_hz;
        Alcotest.(check int) "limit" 100 limit_hz
    | Some kind ->
        Alcotest.failf "unexpected security error: %s"
          (Eta_http.Error.kind_name kind)
    | None -> Alcotest.fail "PING churn was not detected"

  let test_h2_security_header_churn () =
    let frame =
      h2_frame_header ~length:0 ~frame_type:0x1 ~flags:0x4 ~stream_id:1
    in
    let data = String.concat "" (List.init 33 (fun _ -> frame)) in
    match h2_observe_security data with
    | Some
        (Eta_http.Error.Response_header_change_rate_exceeded
          { observed_rate_hz; limit_hz }) ->
        Alcotest.(check int) "observed" 33 observed_rate_hz;
        Alcotest.(check int) "limit" 32 limit_hz
    | Some kind ->
        Alcotest.failf "unexpected security error: %s"
          (Eta_http.Error.kind_name kind)
    | None -> Alcotest.fail "header churn was not detected"

  let test_h2_security_allows_many_normal_response_headers () =
    let frame stream_id =
      h2_frame_header ~length:0 ~frame_type:0x1 ~flags:0x4 ~stream_id
    in
    let data =
      String.concat "" (List.init 100 (fun index -> frame ((index * 2) + 1)))
    in
    match h2_observe_security data with
    | None -> ()
    | Some kind ->
        Alcotest.failf "normal response headers tripped security: %s"
          (Eta_http.Error.kind_name kind)

  let test_h2_security_forgets_completed_stream_headers () =
    let config =
      {
        Eta_http.H2.Security.default_config with
        max_response_headers_per_connection = 1;
      }
    in
    let security = Eta_http.H2.Security.create ~config () in
    let frame =
      h2_frame_header ~length:0 ~frame_type:0x1 ~flags:0x4 ~stream_id:1
    in
    let observe () =
      let bs = Bigstringaf.of_string ~off:0 ~len:(String.length frame) frame in
      Eta_http.H2.Security.observe security bs ~off:0 ~len:(String.length frame)
    in
    (match observe () with
    | None -> ()
    | Some kind ->
        Alcotest.failf "first headers tripped security: %s"
          (Eta_http.Error.kind_name kind));
    Eta_http.H2.Security.complete_stream security 1;
    match observe () with
    | None -> ()
    | Some kind ->
        Alcotest.failf "completed stream header state was retained: %s"
          (Eta_http.Error.kind_name kind)

  let test_h2_security_multiplexer_release_forgets_stream_headers () =
    let config =
      {
        Eta_http.H2.Security.default_config with
        max_response_headers_per_connection = 1;
      }
    in
    let security = Eta_http.H2.Security.create ~config () in
    let mux = Eta_http_eio.H2.Multiplexer.create ~security () in
    let request =
      H2.Request.create ~scheme:"https"
        ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
        `GET "/release"
    in
    let opened =
      match
        Eta_http_eio.H2.Multiplexer.request mux ~tag:1 request
          ~error_handler:(fun _ _ -> Alcotest.fail "unexpected stream error")
          ~response_handler:(fun _ _ _ -> Alcotest.fail "unexpected response")
      with
      | Ok opened -> opened
      | Error (Eta_http_eio.H2.Multiplexer.Admission_rejected { limit }) ->
          Alcotest.failf "request rejected by admission limit %d" limit
      | Error Eta_http_eio.H2.Multiplexer.Connection_closed ->
          Alcotest.fail "request rejected by closed connection"
      | Error (Eta_http_eio.H2.Multiplexer.Request_failed message) ->
          Alcotest.failf "request failed: %s" message
    in
    H2.Body.Writer.close opened.request_body;
    let frame =
      h2_frame_header ~length:0 ~frame_type:0x1 ~flags:0x4 ~stream_id:1
    in
    let observe () =
      let bs = Bigstringaf.of_string ~off:0 ~len:(String.length frame) frame in
      Eta_http.H2.Security.observe security bs ~off:0 ~len:(String.length frame)
    in
    (match observe () with
    | None -> ()
    | Some kind ->
        Alcotest.failf "first headers tripped security: %s"
          (Eta_http.Error.kind_name kind));
    ignore (Eta_http_eio.H2.Multiplexer.release mux opened.stream);
    match observe () with
    | None -> ()
    | Some kind ->
        Alcotest.failf "released stream header state was retained: %s"
          (Eta_http.Error.kind_name kind)

  let expect_h2_header_invalid label headers =
    match Eta_http.H2.Security.validate_headers headers with
    | Some (Eta_http.Error.Header_invalid _) -> ()
    | Some kind ->
        Alcotest.failf "%s unexpected error: %s" label
          (Eta_http.Error.kind_name kind)
    | None -> Alcotest.failf "%s was accepted" label

  let test_h2_security_header_normalization_edges () =
    expect_h2_header_invalid "empty" [ "", "value" ];
    expect_h2_header_invalid "nul name" [ "x\000bad", "value" ];
    expect_h2_header_invalid "nul value" [ "x-good", "bad\000value" ];
    expect_h2_header_invalid "uppercase" [ "X-Bad", "value" ];
    expect_h2_header_invalid "crlf name" [ "x-good\r\ninjected", "value" ];
    expect_h2_header_invalid "crlf value" [ "x-good", "ok\r\ninjected: 1" ];
    expect_h2_header_invalid "lf value" [ "x-good", "ok\ninjected: 1" ];
    expect_h2_header_invalid "cr value" [ "x-good", "ok\rinjected: 1" ];
    expect_h2_header_invalid "obs-fold value" [ "x-good", "ok\n injected: 1" ];
    expect_h2_header_invalid "bad token name" [ "x bad", "value" ];
    expect_h2_header_invalid "long name"
      [ String.make (8 * 1024 + 1) 'x', "value" ];
    expect_h2_header_invalid "long value"
      [ "x-good", String.make (64 * 1024 + 1) 'x' ];
    Alcotest.(check bool) "valid" true
      (Option.is_none
         (Eta_http.H2.Security.validate_headers [ "x-good", "value" ]))

  let test_auto_client_uses_alpn_dispatch_state () =
    let source = read_file (find_http_client_source ()) in
    ignore (require_sub source ~needle:"type alpn_gate = {" : int);
    ignore
      (require_sub source
         ~needle:"alpn_gates : (string, alpn_gate) Hashtbl.t;" : int);
    ignore (require_sub source ~needle:"let begin_alpn state key =" : int);
    ignore (require_sub source ~needle:"Alpn.begin_request gate.alpn" : int);
    ignore (require_sub source ~needle:"Eio.Promise.await pending.promise" : int);
    ignore (require_sub source ~needle:"Alpn.resolve gate.alpn pending protocol" : int);
    ignore (require_sub source ~needle:"Alpn.cancel gate.alpn pending" : int);
    ignore (require_sub source ~needle:"begin_alpn state key" : int)

  let test_alpn_state_collapses_pending_first_arrivals () =
    let module A = Eta_http.Transport.Alpn in
    let alpn = A.create () in
    let leader =
      match A.begin_request alpn with
      | A.Leader pending -> pending
      | A.Wait _ | A.Ready _ -> Alcotest.fail "expected first request leader"
    in
    let waiter =
      match A.begin_request alpn with
      | A.Wait pending -> pending
      | A.Leader _ | A.Ready _ -> Alcotest.fail "expected second request waiter"
    in
    Alcotest.(check int) "same pending"
      (A.pending_id leader)
      (A.pending_id waiter);
    (match A.resolve alpn leader A.H2 with
    | A.Installed A.H2 -> ()
    | _ -> Alcotest.fail "expected h2 installation");
    (match A.begin_request alpn with
    | A.Ready A.H2 -> ()
    | A.Leader _ | A.Wait _ | A.Ready A.H1 ->
        Alcotest.fail "expected h2 ready route");
    let stats = A.stats alpn in
    Alcotest.(check int) "leaders" 1 stats.leaders;
    Alcotest.(check int) "waiters" 1 stats.waiters;
    Alcotest.(check int) "redundant cancelled" 1 stats.redundant_cancelled;
    Alcotest.(check int) "h2 resolved" 1 stats.h2_resolved

  let test_alpn_state_ignores_stale_resolution_and_decodes_protocols () =
    let module A = Eta_http.Transport.Alpn in
    let alpn = A.create () in
    let first =
      match A.begin_request alpn with
      | A.Leader pending -> pending
      | A.Wait _ | A.Ready _ -> Alcotest.fail "expected first leader"
    in
    A.cancel alpn first;
    let second =
      match A.begin_request alpn with
      | A.Leader pending -> pending
      | A.Wait _ | A.Ready _ -> Alcotest.fail "expected second leader"
    in
    (match A.resolve alpn first A.H2 with
    | A.Ignored -> ()
    | A.Installed _ | A.Already_ready _ ->
        Alcotest.fail "stale pending resolved");
    (match A.resolve alpn second A.H1 with
    | A.Installed A.H1 -> ()
    | _ -> Alcotest.fail "expected h1 installation");
    Alcotest.(check (result bool string)) "decode h2" (Ok true)
      (Result.map (( = ) A.H2) (A.protocol_of_alpn (Some "h2")));
    Alcotest.(check (result bool string)) "decode h1" (Ok true)
      (Result.map (( = ) A.H1) (A.protocol_of_alpn (Some "http/1.1")));
    Alcotest.(check (result bool string)) "missing ALPN falls back h1" (Ok true)
      (Result.map (( = ) A.H1) (A.protocol_of_alpn None));
    Alcotest.(check (result bool string)) "unknown ALPN rejected"
      (Error "spdy/3")
      (Result.map (( = ) A.H1) (A.protocol_of_alpn (Some "spdy/3")))

  let test_dispatch_decides_alpn_route () =
    let module D = Eta_http.Transport.Dispatch in
    (match D.decide_alpn (Some "h2") with
    | Ok D.Use_h2 -> ()
    | Ok D.Use_h1 -> Alcotest.fail "h2 ALPN routed to h1"
    | Error protocol -> Alcotest.failf "h2 ALPN rejected: %s" protocol);
    (match D.decide_alpn (Some "http/1.1") with
    | Ok D.Use_h1 -> ()
    | Ok D.Use_h2 -> Alcotest.fail "http/1.1 ALPN routed to h2"
    | Error protocol -> Alcotest.failf "http/1.1 ALPN rejected: %s" protocol);
    (match D.decide_alpn None with
    | Ok D.Use_h1 -> ()
    | Ok D.Use_h2 -> Alcotest.fail "missing ALPN routed to h2"
    | Error protocol -> Alcotest.failf "missing ALPN rejected: %s" protocol);
    Alcotest.(check (result string string)) "unknown ALPN" (Error "spdy/3")
      (Result.map
         (fun decision ->
           D.protocol_to_string (D.decision_protocol decision))
         (D.decide_alpn (Some "spdy/3")))

  let test_tls_chokepoint_policy () =
    let client = Eta_http.Tls.Config.default_client () in
    Alcotest.(check bool)
      "TLS 1.2 only" true
      (Eta_http.Tls.Config.policy_version = (`TLS_1_2, `TLS_1_2));
    Alcotest.(check (list string))
      "exact policy ciphers"
      Eta_http.Tls.Config.policy_ciphers
      Eta_http.Tls.Config.policy_ciphers;
    Alcotest.(check (list string))
      "default ALPN" [ "h2"; "http/1.1" ]
      (Eta_http.Tls.Config.alpn_protocols client)

  let test_body_stream_release_once () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let released = ref 0 in
    let stream =
      Eta_http.Body.Stream.of_bytes
        ~release:(fun () ->
          incr released;
          Eta.Effect.unit)
        [ Bytes.of_string "abc"; Bytes.of_string "def" ]
    in
    let body = B.run rt (Eta_http.Body.Stream.read_all stream) |> expect_ok in
    Alcotest.(check string) "body" "abcdef" (Bytes.to_string body);
    ignore (B.run rt (Eta_http.Body.Stream.discard stream) |> expect_ok);
    Alcotest.(check int) "release once" 1 !released

  let test_body_stream_reader_release_once () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let released = ref 0 in
    let values =
      ref
        [
          Eta_http.Body.Stream.Chunk (Bytes.of_string "a");
          Eta_http.Body.Stream.Last (Bytes.of_string "b");
        ]
    in
    let stream =
      Eta_http.Body.Stream.of_reader
        ~release:(fun () ->
          incr released;
          Eta.Effect.unit)
        (fun () ->
          match !values with
          | [] -> Eta.Effect.pure Eta_http.Body.Stream.End
          | next :: rest ->
              values := rest;
              Eta.Effect.pure next)
    in
    let body = B.run rt (Eta_http.Body.Stream.read_all stream) |> expect_ok in
    Alcotest.(check string) "body" "ab" (Bytes.to_string body);
    ignore (B.run rt (Eta_http.Body.Stream.discard stream) |> expect_ok);
    Alcotest.(check int) "release once" 1 !released

  let rec body_stream_concurrent_use = function
    | Eta.Cause.Fail
        {
          Eta_http.Error.kind =
            Decode_error { codec = "body-stream"; message };
          _;
        } ->
        contains message "concurrent"
    | Eta.Cause.Fail _ | Eta.Cause.Die _ | Eta.Cause.Interrupt _ -> false
    | Eta.Cause.Sequential causes | Eta.Cause.Concurrent causes ->
        List.exists body_stream_concurrent_use causes
    | Eta.Cause.Finalizer _ -> false
    | Eta.Cause.Suppressed { primary; finalizer } ->
        ignore finalizer;
        body_stream_concurrent_use primary

  let test_body_stream_rejects_concurrent_reads () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let read_calls = ref 0 in
    let first_started, first_started_resolver = B.create_promise () in
    let first_unblocked = ref false in
    let first_unblock, first_unblock_resolver = B.create_promise () in
    let unblock_first () =
      if not !first_unblocked then (
        first_unblocked := true;
        B.resolve first_unblock_resolver ())
    in
    let stream =
      Eta_http.Body.Stream.of_reader (fun () ->
          Eta.Effect.sync (fun () ->
              incr read_calls;
              match !read_calls with
              | 1 ->
                  B.resolve first_started_resolver ();
                  ()
              | _ -> ())
          |> Eta.Effect.bind (fun () ->
                 match !read_calls with
                 | 1 ->
                     B.await_effect first_unblock
                     |> Eta.Effect.map (fun () ->
                            Eta_http.Body.Stream.Chunk
                              (Bytes.of_string "first"))
                 | _ ->
                     Eta.Effect.pure
                       (Eta_http.Body.Stream.Last
                          (Bytes.of_string "second"))))
    in
    let first = Eta_http.Body.Stream.read stream in
    let second =
      B.await_effect first_started
      |> Eta.Effect.bind (fun () -> Eta_http.Body.Stream.read stream)
      |> Eta.Effect.finally (Eta.Effect.sync unblock_first)
    in
    (match B.run rt (Eta.Effect.par first second) with
    | Eta.Exit.Error cause when body_stream_concurrent_use cause -> ()
    | Eta.Exit.Error cause ->
        Alcotest.failf "unexpected concurrent read failure: %a"
          (Eta.Cause.pp Eta_http.Error.pp)
          cause
    | Eta.Exit.Ok _ -> Alcotest.fail "concurrent reads both succeeded");
    Alcotest.(check int) "second read did not enter reader" 1 !read_calls

  let test_body_source_owned_stream_releases_on_scope_exit () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let released = ref 0 in
    let stream =
      Eta_http.Body.Stream.of_bytes
        ~release:(fun () ->
          incr released;
          Eta.Effect.unit)
        [ Bytes.of_string "abc" ]
    in
    let eff =
      Eta_http.Body.Source.with_owned_stream
        (Eta_http.Body.Source.stream stream)
        (function
          | None -> Alcotest.fail "expected owned stream"
          | Some owned ->
              Alcotest.(check (option int)) "length" None owned.length;
              Eta.Effect.unit)
    in
    ignore (B.run rt eff |> expect_ok);
    Alcotest.(check int) "released" 1 !released

  let test_body_source_rewindable_stream_is_owned_per_call () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let made = ref 0 in
    let released = ref 0 in
    let source =
      Eta_http.Body.Source.rewindable ~length:3 (fun () ->
          incr made;
          Eta_http.Body.Stream.of_bytes
            ~release:(fun () ->
              incr released;
              Eta.Effect.unit)
            [ Bytes.of_string "abc" ])
    in
    let run_once () =
      Eta_http.Body.Source.with_owned_stream source (function
        | None -> Alcotest.fail "expected owned stream"
        | Some owned ->
            Alcotest.(check (option int)) "length" (Some 3) owned.length;
            Eta_http.Body.Stream.read_all owned.stream |> Eta.Effect.map ignore)
      |> B.run rt |> expect_ok
    in
    run_once ();
    run_once ();
    Alcotest.(check int) "made" 2 !made;
    Alcotest.(check int) "released" 2 !released

  let test_body_stream_read_all_caps_default () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let stream =
      Eta_http.Body.Stream.of_bytes
        [ Bytes.make body_size_cap 'a'; Bytes.of_string "b" ]
    in
    B.run rt (Eta_http.Body.Stream.read_all stream)
    |> expect_body_too_large "read_all" ~limit:body_size_cap

  let chunked_reader_of_string context raw =
    let offset = ref 0 in
    let fail message =
      Eta.Effect.fail
        (Eta_http.Error.make ~protocol:context.Eta_http.Body.Chunked.protocol
           ~method_:context.method_ ~uri:context.uri
           (Decode_error { codec = "chunked-fixture"; message }))
    in
    let read_exact n =
      if n < 0 then invalid_arg "read_exact"
      else if !offset + n > String.length raw then fail "fixture EOF"
      else
        let chunk = Bytes.of_string (String.sub raw !offset n) in
        offset := !offset + n;
        Eta.Effect.pure chunk
    in
    let read_line ~limit =
      let rec loop index =
        if index - !offset > limit then fail "line too long"
        else if index + 1 >= String.length raw then fail "line EOF"
        else if
          Char.equal raw.[index] '\r' && Char.equal raw.[index + 1] '\n'
        then
          let line = String.sub raw !offset (index - !offset) in
          offset := index + 2;
          Eta.Effect.pure line
        else loop (index + 1)
      in
      loop !offset
    in
    { Eta_http.Body.Chunked.read_exact; read_line }

  let chunked_context =
    {
      Eta_http.Body.Chunked.protocol = Eta_http.Error.H1;
      method_ = "GET";
      uri = "http://example.test/chunked";
    }

  let test_chunked_decodes_trailers () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let reader =
      chunked_reader_of_string chunked_context
        " 4 \r\nWiki\r\n 5 ;ext=1\r\npedia\r\n0\r\nX-Trailer: ok\r\n\r\n"
    in
    let decoder =
      Eta_http.Body.Chunked.create ~context:chunked_context ~reader ()
    in
    let body =
      let rec loop acc =
        Eta_http.Body.Chunked.read decoder
        |> Eta.Effect.bind (function
             | None -> Eta.Effect.pure (Bytes.concat Bytes.empty (List.rev acc))
             | Some chunk -> loop (chunk :: acc))
      in
      B.run rt (loop []) |> expect_ok
    in
    Alcotest.(check string) "decoded" "Wikipedia" (Bytes.to_string body);
    Alcotest.(check (option string))
      "trailer" (Some "ok")
      (Eta_http.Core.Header.get "x-trailer"
         (Eta_http.Body.Chunked.trailers decoder))

  let test_chunked_decoder_rejects_invalid_trailer_header () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let reader =
      chunked_reader_of_string chunked_context "0\r\nBad Name: nope\r\n\r\n"
    in
    let decoder =
      Eta_http.Body.Chunked.create ~context:chunked_context ~reader ()
    in
    match B.run rt (Eta_http.Body.Chunked.read decoder) with
    | Eta.Exit.Error
        (Eta.Cause.Fail
          { Eta_http.Error.kind = Decode_error { message; _ }; _ }) ->
        Alcotest.(check bool) "trailer validation error" true
          (contains message "trailer")
    | Eta.Exit.Error cause ->
        Alcotest.failf "unexpected failure: %a"
          (Eta.Cause.pp Eta_http.Error.pp)
          cause
    | Eta.Exit.Ok _ -> Alcotest.fail "invalid trailer was accepted"

  let test_chunked_decoder_rejects_oversized_trailers () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let reader =
      chunked_reader_of_string chunked_context
        "0\r\nX-Too-Large: value\r\n\r\n"
    in
    let decoder =
      Eta_http.Body.Chunked.create ~max_trailer_bytes:8
        ~context:chunked_context ~reader ()
    in
    match B.run rt (Eta_http.Body.Chunked.read decoder) with
    | Eta.Exit.Error
        (Eta.Cause.Fail
          { Eta_http.Error.kind = Decode_error { message; _ }; _ }) ->
        Alcotest.(check bool) "trailer size error" true
          (contains message "trailer section too large")
    | Eta.Exit.Error cause ->
        Alcotest.failf "unexpected failure: %a"
          (Eta.Cause.pp Eta_http.Error.pp)
          cause
    | Eta.Exit.Ok _ -> Alcotest.fail "oversized trailers were accepted"

  let test_chunked_decoder_rejects_too_many_trailers () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let reader =
      chunked_reader_of_string chunked_context
        "0\r\nX-One: 1\r\nX-Two: 2\r\n\r\n"
    in
    let decoder =
      Eta_http.Body.Chunked.create ~max_trailers:1
        ~context:chunked_context ~reader ()
    in
    match B.run rt (Eta_http.Body.Chunked.read decoder) with
    | Eta.Exit.Error
        (Eta.Cause.Fail
          { Eta_http.Error.kind = Decode_error { message; _ }; _ }) ->
        Alcotest.(check bool) "trailer count error" true
          (contains message "too many trailers")
    | Eta.Exit.Error cause ->
        Alcotest.failf "unexpected failure: %a"
          (Eta.Cause.pp Eta_http.Error.pp)
          cause
    | Eta.Exit.Ok _ -> Alcotest.fail "too many trailers were accepted"

  let test_chunked_encoder () =
    let encoded =
      Eta_http.Body.Chunked.encode_chunk (Bytes.of_string "abcdefghijklmnop")
    in
    let encoded = Bytes.concat Bytes.empty encoded |> Bytes.to_string in
    Alcotest.(check string) "chunk" "10\r\nabcdefghijklmnop\r\n" encoded;
    let trailers = Eta_http.Core.Header.unsafe_of_list [ ("x-trailer", "ok") ] in
    let last =
      Eta_http.Body.Chunked.encode_last_chunk ~trailers () |> Bytes.to_string
    in
    Alcotest.(check string) "last" "0\r\nx-trailer: ok\r\n\r\n" last

  let test_chunked_encoder_rejects_invalid_trailers () =
    let trailers =
      Eta_http.Core.Header.unsafe_of_list
        [ ("X-Good", "ok\r\nX-Evil: yes") ]
    in
    Alcotest.check_raises "invalid trailer rejected"
      (Invalid_argument
         "Eta_http.Body.Chunked.encode_last_chunk: invalid trailer header")
      (fun () ->
        ignore (Eta_http.Body.Chunked.encode_last_chunk ~trailers () : bytes))

  let test_chunked_decoder_rejects_forbidden_content_length_trailer () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let reader =
      chunked_reader_of_string chunked_context
        "0\r\nContent-Length: 999\r\n\r\n"
    in
    let decoder =
      Eta_http.Body.Chunked.create ~context:chunked_context ~reader ()
    in
    match B.run rt (Eta_http.Body.Chunked.read decoder) with
    | Eta.Exit.Error
        (Eta.Cause.Fail
          {
            Eta_http.Error.kind = Decode_error { codec = "chunked"; message };
            _;
          }) ->
        Alcotest.(check bool)
          "mentions forbidden trailer" true
          (contains message "Content-Length")
    | Eta.Exit.Ok None ->
        Alcotest.fail "forbidden Content-Length trailer was accepted"
    | Eta.Exit.Ok (Some _) ->
        Alcotest.fail "unexpected chunk while reading zero-size chunk trailers"
    | Eta.Exit.Error cause ->
        Alcotest.failf "unexpected failure: %a" (Eta.Cause.pp Eta_http.Error.pp)
          cause

  let test_chunked_encoder_rejects_forbidden_content_length_trailer () =
    match
      Eta_http.Body.Chunked.encode_last_chunk
        ~trailers:[ ("Content-Length", "999") ]
        ()
    with
    | _ -> Alcotest.fail "encoded forbidden Content-Length trailer"
    | exception Invalid_argument message ->
        Alcotest.(check bool)
          "mentions Content-Length" true
          (contains message "Content-Length")

  let gzip_compress rt value =
    let input = Eta_http.Body.Stream.of_bytes [ Bytes.of_string value ] in
    let encoded = Eta_http.Body.Transducer.gzip_encode input in
    B.run rt (Eta_http.Body.Stream.read_all encoded) |> expect_ok

  let test_gzip_transducer_roundtrip () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let input =
      Eta_http.Body.Stream.of_bytes
        [
          Bytes.of_string "alpha";
          Bytes.of_string "-beta";
          Bytes.of_string "-gamma";
        ]
    in
    let encoded = Eta_http.Body.Transducer.gzip_encode input in
    let compressed = B.run rt (Eta_http.Body.Stream.read_all encoded) |> expect_ok in
    Alcotest.(check bool) "compressed non-empty" true
      (Bytes.length compressed > 0);
    let decoded =
      Eta_http.Body.Transducer.gzip_decode
        (Eta_http.Body.Stream.of_bytes [ compressed ])
    in
    let body = B.run rt (Eta_http.Body.Stream.read_all decoded) |> expect_ok in
    Alcotest.(check string) "roundtrip" "alpha-beta-gamma"
      (Bytes.to_string body)

  let test_gzip_transducer_expansion_cap () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let input = Eta_http.Body.Stream.of_bytes [ Bytes.make 4096 'x' ] in
    let encoded = Eta_http.Body.Transducer.gzip_encode input in
    let compressed = B.run rt (Eta_http.Body.Stream.read_all encoded) |> expect_ok in
    let decoded =
      Eta_http.Body.Transducer.gzip_decode ~max_decoded_bytes:1024
        (Eta_http.Body.Stream.of_bytes [ compressed ])
    in
    match B.run rt (Eta_http.Body.Stream.read_all decoded) with
    | Eta.Exit.Ok _ -> Alcotest.fail "gzip expansion cap unexpectedly succeeded"
    | Eta.Exit.Error
        (Eta.Cause.Fail
          { Eta_http.Error.kind = Decode_error { codec; message }; _ }) ->
        Alcotest.(check string) "codec" "gzip" codec;
        Alcotest.(check bool) "message" true (contains message "exceeds")
    | Eta.Exit.Error cause ->
        Alcotest.failf "unexpected gzip failure shape: %a"
          (Eta.Cause.pp Eta_http.Error.pp)
          cause

  let expect_gzip_decode_error rt label bytes =
    let decoded =
      Eta_http.Body.Transducer.gzip_decode
        (Eta_http.Body.Stream.of_bytes [ bytes ])
    in
    match B.run rt (Eta_http.Body.Stream.read_all decoded) with
    | Eta.Exit.Ok _ -> Alcotest.failf "%s unexpectedly decoded" label
    | Eta.Exit.Error
        (Eta.Cause.Fail
          { Eta_http.Error.kind = Decode_error { codec = "gzip"; _ }; _ }) ->
        ()
    | Eta.Exit.Error cause ->
        Alcotest.failf "%s unexpected failure shape: %a" label
          (Eta.Cause.pp Eta_http.Error.pp)
          cause

  let test_gzip_transducer_rejects_truncated_stream () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let compressed = gzip_compress rt "truncated-body" in
    let truncated = Bytes.sub compressed 0 (Bytes.length compressed - 4) in
    expect_gzip_decode_error rt "truncated" truncated

  let test_gzip_transducer_rejects_crc_mismatch () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let compressed = gzip_compress rt "crc-body" in
    let corrupt = Bytes.copy compressed in
    let crc_offset = Bytes.length corrupt - 8 in
    Bytes.set corrupt crc_offset
      (Char.chr (Char.code (Bytes.get corrupt crc_offset) lxor 0xff));
    expect_gzip_decode_error rt "crc" corrupt

  let test_gzip_transducer_decodes_concatenated_members () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let first = gzip_compress rt "hello " in
    let second = gzip_compress rt "world" in
    let concatenated = Bytes.cat first second in
    let decoded =
      Eta_http.Body.Transducer.gzip_decode
        (Eta_http.Body.Stream.of_bytes [ concatenated ])
    in
    let body = B.run rt (Eta_http.Body.Stream.read_all decoded) |> expect_ok in
    Alcotest.(check string) "body" "hello world" (Bytes.to_string body)

  let test_h1_parser_fixed_body () =
    let raw =
      Bytes.of_string
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhelloextra"
    in
    match Eta_http.H1.Parse.parse raw ~len:(Bytes.length raw) with
    | Error error ->
        Alcotest.fail (Eta_http.H1.Parse.parse_error_to_string error)
    | Ok response ->
        Alcotest.(check string) "version" "http/1.1"
          (Eta_http.Core.Version.to_string response.version);
        Alcotest.(check int) "status" 200 response.status;
        Alcotest.(check string) "reason" "OK"
          (Eta_http.H1.Parse.span_to_string raw response.reason);
        Alcotest.(check (list (pair string string)))
          "headers"
          [ ("Content-Type", "text/plain"); ("Content-Length", "5") ]
          (Eta_http.H1.Parse.headers_to_list raw response.headers);
        Alcotest.(check string) "body" "hello"
          (Bytes.to_string (Eta_http.H1.Parse.body_to_bytes raw response))

  let test_h1_parser_no_body_head () =
    let raw = Bytes.of_string "HTTP/1.0 204 No Content\r\nServer: test\r\n\r\n" in
    match Eta_http.H1.Parse.parse raw ~len:(Bytes.length raw) with
    | Error error ->
        Alcotest.fail (Eta_http.H1.Parse.parse_error_to_string error)
    | Ok response ->
        Alcotest.(check string) "version" "http/1.0"
          (Eta_http.Core.Version.to_string response.version);
        Alcotest.(check int) "status" 204 response.status;
        Alcotest.(check string) "reason" "No Content"
          (Eta_http.H1.Parse.span_to_string raw response.reason);
        Alcotest.(check string) "body" ""
          (Bytes.to_string (Eta_http.H1.Parse.body_to_bytes raw response))

  let test_h1_parser_rejects_bad_content_length () =
    let raw =
      Bytes.of_string "HTTP/1.1 200 OK\r\nContent-Length: nope\r\n\r\n"
    in
    match Eta_http.H1.Parse.parse raw ~len:(Bytes.length raw) with
    | Ok _ -> Alcotest.fail "invalid Content-Length unexpectedly parsed"
    | Error error ->
        Alcotest.(check string)
          "error" "invalid Content-Length \"nope\""
          (Eta_http.H1.Parse.parse_error_to_string error)

  let test_h1_parser_rejects_conflicting_content_length () =
    let raw =
      Bytes.of_string
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello"
    in
    match Eta_http.H1.Parse.parse raw ~len:(Bytes.length raw) with
    | Ok _ -> Alcotest.fail "conflicting Content-Length unexpectedly parsed"
    | Error error ->
        Alcotest.(check string)
          "error" "invalid Content-Length \"6\""
          (Eta_http.H1.Parse.parse_error_to_string error)

  let test_h1_parser_rejects_invalid_header_value_controls () =
    let raw =
      Bytes.of_string "HTTP/1.1 200 OK\r\nX-Bad: ok\000bad\r\n\r\n"
    in
    match Eta_http.H1.Parse.parse raw ~len:(Bytes.length raw) with
    | Error (Eta_http.H1.Parse.Invalid_header _) -> ()
    | Error error ->
        Alcotest.failf "expected invalid header, got %s"
          (Eta_http.H1.Parse.parse_error_to_string error)
    | Ok _ -> Alcotest.fail "control byte in header value was accepted"

  let parse_h1_request ?max_request_line_bytes ?max_header_bytes ?max_headers
      raw =
    let buf = Bytes.of_string raw in
    match
      Eta_http.H1.Request_parse.parse ?max_request_line_bytes
        ?max_header_bytes ?max_headers buf ~len:(Bytes.length buf)
    with
    | Ok request -> (buf, request)
    | Error error ->
        Alcotest.fail (Eta_http.H1.Request_parse.parse_error_to_string error)

  let test_h1_request_parser_request_head () =
    let raw =
      "GET /items?token=secret HTTP/1.1\r\nHost: example.test\r\nX-Trace:\t abc \t\r\n\r\nbody"
    in
    let buf, request = parse_h1_request raw in
    Alcotest.(check string) "method" "GET"
      (Eta_http.H1.Request_parse.method_to_string buf request);
    Alcotest.(check string) "target" "/items?token=secret"
      (Eta_http.H1.Request_parse.target_to_string buf request);
    Alcotest.(check string) "version" "http/1.1"
      (Eta_http.Core.Version.to_string request.version);
    Alcotest.(check (list (pair string string)))
      "headers"
      [ ("Host", "example.test"); ("X-Trace", "abc") ]
      (Eta_http.H1.Request_parse.headers_to_list buf request.headers);
    Alcotest.(check string) "body bytes" "body"
      (Bytes.sub_string buf request.body_off (Bytes.length buf - request.body_off))

  let test_h1_request_parser_partial () =
    let buf = Bytes.of_string "GET /items HTTP/1.1\r\nHost: example.test" in
    match
      Eta_http.H1.Request_parse.parse buf ~len:(Bytes.length buf)
    with
    | Error Eta_http.H1.Request_parse.Partial -> ()
    | Error error ->
        Alcotest.failf "expected partial, got %s"
          (Eta_http.H1.Request_parse.parse_error_to_string error)
    | Ok _ -> Alcotest.fail "partial request unexpectedly parsed"

  let test_h1_request_parser_rejects_limits () =
    let request = Bytes.of_string "GET /too-long HTTP/1.1\r\n\r\n" in
    (match
       Eta_http.H1.Request_parse.parse request ~max_request_line_bytes:8
         ~len:(Bytes.length request)
     with
    | Error (Eta_http.H1.Request_parse.Request_line_too_large { limit = 8 }) ->
        ()
    | Error error ->
        Alcotest.failf "expected request line limit, got %s"
          (Eta_http.H1.Request_parse.parse_error_to_string error)
    | Ok _ -> Alcotest.fail "oversized request line unexpectedly parsed");
    let headers =
      Bytes.of_string "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n"
    in
    (match
       Eta_http.H1.Request_parse.parse headers ~max_header_bytes:8
         ~len:(Bytes.length headers)
     with
    | Error (Eta_http.H1.Request_parse.Header_section_too_large { limit = 8 }) ->
        ()
    | Error error ->
        Alcotest.failf "expected header size limit, got %s"
          (Eta_http.H1.Request_parse.parse_error_to_string error)
    | Ok _ -> Alcotest.fail "oversized header section unexpectedly parsed");
    let many =
      Bytes.of_string "GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\n\r\n"
    in
    match
      Eta_http.H1.Request_parse.parse many ~max_headers:1
        ~len:(Bytes.length many)
    with
    | Error (Eta_http.H1.Request_parse.Headers_too_many { limit = 1 }) -> ()
    | Error error ->
        Alcotest.failf "expected header count limit, got %s"
          (Eta_http.H1.Request_parse.parse_error_to_string error)
    | Ok _ -> Alcotest.fail "too many headers unexpectedly parsed"

  let test_h1_request_parser_rejects_invalid_syntax () =
    let method_buf = Bytes.of_string "G\000T / HTTP/1.1\r\n\r\n" in
    (match
       Eta_http.H1.Request_parse.parse method_buf
         ~len:(Bytes.length method_buf)
     with
    | Error (Eta_http.H1.Request_parse.Invalid_method _) -> ()
    | Error error ->
        Alcotest.failf "expected invalid method, got %s"
          (Eta_http.H1.Request_parse.parse_error_to_string error)
    | Ok _ -> Alcotest.fail "invalid method unexpectedly parsed");
    let header_buf =
      Bytes.of_string "GET / HTTP/1.1\r\nX-Bad: ok\000bad\r\n\r\n"
    in
    match
      Eta_http.H1.Request_parse.parse header_buf
        ~len:(Bytes.length header_buf)
    with
    | Error (Eta_http.H1.Request_parse.Invalid_header _) -> ()
    | Error error ->
        Alcotest.failf "expected invalid header, got %s"
          (Eta_http.H1.Request_parse.parse_error_to_string error)
    | Ok _ -> Alcotest.fail "invalid header unexpectedly parsed"

  let expect_h1_request_framing label headers expected =
    match Eta_http.H1.Request_body.of_headers headers with
    | Error error ->
        Alcotest.failf "%s unexpected framing error: %s" label
          (Eta_http.H1.Request_body.error_to_string error)
    | Ok framing ->
        let to_string = function
          | Eta_http.H1.Request_body.No_body -> "no_body"
          | Fixed length -> "fixed:" ^ string_of_int length
          | Chunked -> "chunked"
        in
        Alcotest.(check string) label (to_string expected) (to_string framing)

  let expect_h1_request_framing_error label headers expect =
    match Eta_http.H1.Request_body.of_headers headers with
    | Ok _ -> Alcotest.failf "%s expected framing error" label
    | Error error ->
        if not (expect error) then
          Alcotest.failf "%s unexpected framing error: %s" label
            (Eta_http.H1.Request_body.error_to_string error)

  let test_h1_request_body_framing_no_body_and_fixed () =
    expect_h1_request_framing "absent" [] Eta_http.H1.Request_body.No_body;
    expect_h1_request_framing "fixed"
      [ ("Content-Length", " 5 "); ("Content-Length", "005") ]
      (Eta_http.H1.Request_body.Fixed 5)

  let test_h1_request_body_framing_rejects_content_length () =
    expect_h1_request_framing_error "bad content-length"
      [ ("Content-Length", "nope") ]
      (function
        | Eta_http.H1.Request_body.Invalid_content_length "nope" -> true
        | _ -> false);
    expect_h1_request_framing_error "conflicting content-length"
      [ ("Content-Length", "5"); ("Content-Length", "6") ]
      (function
        | Eta_http.H1.Request_body.Conflicting_content_length
            { first = "5"; second = "6" } ->
            true
        | _ -> false)

  let test_h1_request_body_framing_rejects_transfer_encoding () =
    expect_h1_request_framing_error "cl te"
      [ ("Content-Length", "4"); ("Transfer-Encoding", "chunked") ]
      (function
        | Eta_http.H1.Request_body.Content_length_with_transfer_encoding ->
            true
        | _ -> false);
    expect_h1_request_framing_error "unsupported te"
      [ ("Transfer-Encoding", "gzip") ]
      (function
        | Eta_http.H1.Request_body.Unsupported_transfer_encoding [ "gzip" ] ->
            true
        | _ -> false);
    expect_h1_request_framing_error "non-final chunked"
      [ ("Transfer-Encoding", "chunked, gzip") ]
      (function
        | Eta_http.H1.Request_body.Unsupported_transfer_encoding
            [ "chunked"; "gzip" ] ->
            true
        | _ -> false)

  let test_h1_request_body_framing_chunked_trailers () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    expect_h1_request_framing "chunked"
      [ ("Transfer-Encoding", "chunked"); ("Trailer", "X-Checksum") ]
      Eta_http.H1.Request_body.Chunked;
    let context =
      {
        Eta_http.Body.Chunked.protocol = Eta_http.Error.H1;
        method_ = "POST";
        uri = "http://example.test/upload";
      }
    in
    let reader =
      chunked_reader_of_string context "3\r\nabc\r\n0\r\nX-Checksum: ok\r\n\r\n"
    in
    let decoder =
      Eta_http.Body.Chunked.create ~context ~reader ()
    in
    let body =
      let rec loop acc =
        Eta_http.Body.Chunked.read decoder
        |> Eta.Effect.bind (function
             | None -> Eta.Effect.pure (Bytes.concat Bytes.empty (List.rev acc))
             | Some chunk -> loop (chunk :: acc))
      in
      B.run rt (loop []) |> expect_ok
    in
    Alcotest.(check string) "body" "abc" (Bytes.to_string body);
    Alcotest.(check (option string)) "trailer" (Some "ok")
      (Eta_http.Core.Header.get "x-checksum"
         (Eta_http.Body.Chunked.trailers decoder))

  let expect_h1_response_string ?connection_close ~version ~request_method
      response expected =
    match
      Eta_http.H1.Response_write.to_string ?connection_close ~version
        ~request_method response
    with
    | Error error ->
        Alcotest.fail (Eta_http.H1.Response_write.error_to_string error)
    | Ok wire -> Alcotest.(check string) "wire" expected wire

  let test_h1_response_writer_fixed_body () =
    let response =
      Eta_http.Server.Response.make ~status:200
        ~headers:[ ("Content-Type", "text/plain") ]
        ~body:(Eta_http.Server.Response.Body.fixed [ Bytes.of_string "hello" ])
        ()
    in
    expect_h1_response_string ~version:Eta_http.Core.Version.H1_1
      ~request_method:"GET" response
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello"

  let test_h1_response_writer_head_and_no_body_status () =
    let head_response =
      Eta_http.Server.Response.make ~status:200
        ~body:(Eta_http.Server.Response.Body.fixed [ Bytes.of_string "abc" ])
        ()
    in
    expect_h1_response_string ~version:Eta_http.Core.Version.H1_1
      ~request_method:"HEAD" head_response
      "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n";
    let no_content =
      Eta_http.Server.Response.text ~status:204 "ignored body"
    in
    expect_h1_response_string ~version:Eta_http.Core.Version.H1_1
      ~request_method:"GET" no_content
      "HTTP/1.1 204 No Content\r\n\r\n"

  let test_h1_response_writer_stream_length () =
    let body =
      Eta_http.Server.Response.Body.stream ~length:5 (fun () ->
          Eta.Effect.pure None)
    in
    let response = Eta_http.Server.Response.make ~status:200 ~body () in
    match
      Eta_http.H1.Response_write.prepare ~version:Eta_http.Core.Version.H1_1
        ~request_method:"GET" response
    with
    | Error error ->
        Alcotest.fail (Eta_http.H1.Response_write.error_to_string error)
    | Ok prepared ->
        Alcotest.(check string) "head"
          "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n"
          prepared.head;
        Alcotest.(check bool) "close" false prepared.close;
        (match prepared.body with
        | Eta_http.H1.Response_write.Stream_fixed stream ->
            Alcotest.(check (option int)) "length" (Some 5) stream.length
        | _ -> Alcotest.fail "expected fixed stream framing")

  let test_h1_response_writer_chunked_stream_and_trailers () =
    let body =
      Eta_http.Server.Response.Body.stream (fun () -> Eta.Effect.pure None)
    in
    let response =
      Eta_http.Server.Response.make ~status:200
        ~headers:[ ("Trailer", "X-Done") ] ~body ()
    in
    match
      Eta_http.H1.Response_write.prepare ~version:Eta_http.Core.Version.H1_1
        ~request_method:"GET" response
    with
    | Error error ->
        Alcotest.fail (Eta_http.H1.Response_write.error_to_string error)
    | Ok prepared ->
        Alcotest.(check string) "head"
          "HTTP/1.1 200 OK\r\nTrailer: X-Done\r\nTransfer-Encoding: chunked\r\n\r\n"
          prepared.head;
        (match prepared.body with
        | Eta_http.H1.Response_write.Stream_chunked _ -> ()
        | _ -> Alcotest.fail "expected chunked stream framing");
        Alcotest.(check string) "chunk" "3\r\nabc\r\n"
          (Bytes.to_string
             (Bytes.concat Bytes.empty
                (Eta_http.H1.Response_write.encode_chunk
                   (Bytes.of_string "abc"))));
        Alcotest.(check string) "last chunk"
          "0\r\nX-Done: yes\r\n\r\n"
          (Bytes.to_string
             (Eta_http.H1.Response_write.encode_last_chunk
                ~trailers:[ ("X-Done", "yes") ]
                ()))

  let test_h1_response_writer_http10_close_delimited_stream () =
    let body =
      Eta_http.Server.Response.Body.stream (fun () -> Eta.Effect.pure None)
    in
    let response = Eta_http.Server.Response.make ~status:200 ~body () in
    match
      Eta_http.H1.Response_write.prepare ~version:Eta_http.Core.Version.H1_0
        ~request_method:"GET" response
    with
    | Error error ->
        Alcotest.fail (Eta_http.H1.Response_write.error_to_string error)
    | Ok prepared ->
        Alcotest.(check string) "head"
          "HTTP/1.0 200 OK\r\nConnection: close\r\n\r\n"
          prepared.head;
        Alcotest.(check bool) "close" true prepared.close;
        (match prepared.body with
        | Eta_http.H1.Response_write.Stream_close_delimited _ -> ()
        | _ -> Alcotest.fail "expected close-delimited stream framing")

  let test_h1_response_writer_rejects_caller_framing_headers () =
    let response =
      Eta_http.Server.Response.text ~headers:[ ("Content-Length", "999") ]
        "hello"
    in
    match
      Eta_http.H1.Response_write.prepare ~version:Eta_http.Core.Version.H1_1
        ~request_method:"GET" response
    with
    | Error (Eta_http.H1.Response_write.Caller_framing_header "Content-Length") ->
        ()
    | Error error ->
        Alcotest.failf "unexpected error: %s"
          (Eta_http.H1.Response_write.error_to_string error)
    | Ok _ -> Alcotest.fail "caller framing header unexpectedly accepted"

  let test_h1_response_writer_rejects_hop_by_hop_headers () =
    let response =
      Eta_http.Server.Response.text ~headers:[ ("Connection", "keep-alive") ]
        "hello"
    in
    match
      Eta_http.H1.Response_write.prepare ~version:Eta_http.Core.Version.H1_1
        ~request_method:"GET" response
    with
    | Error (Eta_http.H1.Response_write.Caller_hop_by_hop_header "Connection") ->
        ()
    | Error error ->
        Alcotest.failf "unexpected error: %s"
          (Eta_http.H1.Response_write.error_to_string error)
    | Ok _ -> Alcotest.fail "hop-by-hop header unexpectedly accepted"

  let test_h1_response_writer_rejects_trailer_without_chunked_body () =
    let response =
      Eta_http.Server.Response.text ~headers:[ ("Trailer", "X-Done") ] "hello"
    in
    match
      Eta_http.H1.Response_write.prepare ~version:Eta_http.Core.Version.H1_1
        ~request_method:"GET" response
    with
    | Error Eta_http.H1.Response_write.Trailer_without_chunked_body -> ()
    | Error error ->
        Alcotest.failf "unexpected error: %s"
          (Eta_http.H1.Response_write.error_to_string error)
    | Ok _ -> Alcotest.fail "fixed-body Trailer header unexpectedly accepted"

  let test_h1_response_writer_rejects_invalid_trailer_names () =
    let body =
      Eta_http.Server.Response.Body.stream (fun () -> Eta.Effect.pure None)
    in
    let response =
      Eta_http.Server.Response.make ~status:200
        ~headers:[ ("Trailer", "Bad Name") ] ~body ()
    in
    match
      Eta_http.H1.Response_write.prepare ~version:Eta_http.Core.Version.H1_1
        ~request_method:"GET" response
    with
    | Error (Eta_http.H1.Response_write.Invalid_trailer_name "Bad Name") -> ()
    | Error error ->
        Alcotest.failf "unexpected error: %s"
          (Eta_http.H1.Response_write.error_to_string error)
    | Ok _ -> Alcotest.fail "invalid Trailer name unexpectedly accepted"

  let test_h1_response_writer_rejects_forbidden_trailer_names () =
    let body =
      Eta_http.Server.Response.Body.stream (fun () -> Eta.Effect.pure None)
    in
    let response =
      Eta_http.Server.Response.make ~status:200
        ~headers:[ ("Trailer", "X-Done, Content-Length") ] ~body ()
    in
    match
      Eta_http.H1.Response_write.prepare ~version:Eta_http.Core.Version.H1_1
        ~request_method:"GET" response
    with
    | Error
        (Eta_http.H1.Response_write.Forbidden_trailer_name "Content-Length") ->
        ()
    | Error error ->
        Alcotest.failf "unexpected error: %s"
          (Eta_http.H1.Response_write.error_to_string error)
    | Ok _ -> Alcotest.fail "forbidden Trailer name unexpectedly accepted"

  let test_h1_writer_get_origin_form () =
    let url =
      Eta_http.Core.Url.of_string
        "https://api.example.test:8443/v1/models?limit=1#frag"
    in
    let request =
      Eta_http.H1.Write.to_string ~method_:"GET" ~url
        ~headers:[ ("Accept", "application/json") ]
        ~body:Eta_http.H1.Write.Empty
    in
    match request with
    | Error error -> Alcotest.fail (Eta_http.Error.to_string error)
    | Ok request ->
        Alcotest.(check string)
          "wire request"
          "GET /v1/models?limit=1 HTTP/1.1\r\n\
           Host: api.example.test:8443\r\n\
           Connection: keep-alive\r\n\
           Accept: application/json\r\n\
           \r\n"
          request

  let test_h1_writer_fixed_body () =
    let url = Eta_http.Core.Url.of_string "http://example.test/echo" in
    let request =
      Eta_http.H1.Write.to_string ~method_:"POST" ~url ~headers:[]
        ~body:
          (Eta_http.H1.Write.Fixed
             [ Bytes.of_string "abc"; Bytes.of_string "def" ])
    in
    match request with
    | Error error -> Alcotest.fail (Eta_http.Error.to_string error)
    | Ok request ->
        Alcotest.(check string)
          "wire request"
          "POST /echo HTTP/1.1\r\n\
           Host: example.test\r\n\
           Connection: keep-alive\r\n\
           Content-Length: 6\r\n\
           \r\n\
           abcdef"
          request

  let expect_h1_content_length_invalid label = function
    | Error { Eta_http.Error.kind = Header_invalid { reason }; _ } ->
        Alcotest.(check bool)
          (label ^ " mentions Content-Length")
          true
          (contains reason "Content-Length")
    | Error error ->
        Alcotest.failf "%s unexpected error: %s" label
          (Eta_http.Error.to_string error)
    | Ok wire ->
        Alcotest.failf "%s serialized invalid request: %S" label wire

  let expect_h1_content_length_invalid_len label bytes = function
    | Error { Eta_http.Error.kind = Header_invalid { reason }; _ } ->
        Alcotest.(check bool)
          (label ^ " mentions Content-Length")
          true
          (contains reason "Content-Length")
    | Error error ->
        Alcotest.failf "%s unexpected error: %s" label
          (Eta_http.Error.to_string error)
    | Ok len ->
        let wire = Bytes.sub_string bytes 0 len in
        Alcotest.failf "%s serialized invalid request: %S" label wire

  let test_h1_writer_rejects_mismatched_content_length () =
    let url = Eta_http.Core.Url.of_string "http://example.test/echo" in
    match
      Eta_http.H1.Write.to_string ~method_:"POST" ~url
        ~headers:[ ("Content-Length", "3") ]
        ~body:(Eta_http.H1.Write.Fixed [ Bytes.of_string "abcdef" ])
    with
    | Error { Eta_http.Error.kind = Header_invalid { reason }; _ } ->
        Alcotest.(check bool)
          "mentions Content-Length" true
          (contains reason "Content-Length")
    | Error error -> Alcotest.fail (Eta_http.Error.to_string error)
    | Ok wire -> Alcotest.failf "serialized mismatched request: %S" wire

  let test_h1_writer_rejects_invalid_content_length_framing () =
    let url = Eta_http.Core.Url.of_string "http://example.test/echo" in
    let cases =
      [
        ( "invalid",
          [ ("Content-Length", "nope") ],
          Eta_http.H1.Write.Fixed [ Bytes.of_string "abcdef" ] );
        ( "duplicate conflict",
          [ ("Content-Length", "6"); ("Content-Length", "3") ],
          Eta_http.H1.Write.Fixed [ Bytes.of_string "abcdef" ] );
        ( "empty mismatch",
          [ ("Content-Length", "1") ],
          Eta_http.H1.Write.Empty );
        ( "content length with transfer encoding",
          [ ("Content-Length", "6"); ("Transfer-Encoding", "chunked") ],
          Eta_http.H1.Write.Fixed [ Bytes.of_string "abcdef" ] );
      ]
    in
    List.iter
      (fun (label, headers, body) ->
        Eta_http.H1.Write.to_string ~method_:"POST" ~url ~headers ~body
        |> expect_h1_content_length_invalid (label ^ " string");
        let bytes = Bytes.create 512 in
        Eta_http.H1.Write.write_to_bytes bytes ~pos:0 ~method_:"POST" ~url
          ~headers ~body
        |> expect_h1_content_length_invalid_len (label ^ " bytes") bytes)
      cases

  let test_h1_writer_rejects_transfer_encoding_for_fixed_body () =
    let url = Eta_http.Core.Url.of_string "http://example.test/echo" in
    let headers = [ ("Transfer-Encoding", "chunked") ] in
    let body = Eta_http.H1.Write.Fixed [ Bytes.of_string "abcdef" ] in
    let expect_rejected label = function
      | Error { Eta_http.Error.kind = Header_invalid { reason }; _ } ->
          Alcotest.(check bool)
            (label ^ " mentions Transfer-Encoding")
            true
            (contains reason "Transfer-Encoding")
      | Error error ->
          Alcotest.failf "%s unexpected error: %s" label
            (Eta_http.Error.to_string error)
      | Ok wire ->
          Alcotest.failf "%s serialized invalid request: %S" label wire
    in
    Eta_http.H1.Write.to_string ~method_:"POST" ~url ~headers ~body
    |> expect_rejected "string";
    let bytes = Bytes.create 512 in
    match
      Eta_http.H1.Write.write_to_bytes bytes ~pos:0 ~method_:"POST" ~url
        ~headers ~body
    with
    | Error { Eta_http.Error.kind = Header_invalid { reason }; _ } ->
        Alcotest.(check bool)
          "bytes mentions Transfer-Encoding" true
          (contains reason "Transfer-Encoding")
    | Error error -> Alcotest.fail (Eta_http.Error.to_string error)
    | Ok len ->
        Alcotest.failf "bytes serialized invalid request: %S"
          (Bytes.sub_string bytes 0 len)

  let test_h1_writer_bytes_matches_string_writer () =
    let url =
      Eta_http.Core.Url.of_string
        "https://API.Example.test:8443/v1/models?limit=1#frag"
    in
    let headers = [ ("Accept", "application/json") ] in
    let body = Eta_http.H1.Write.Empty in
    let expected =
      Eta_http.H1.Write.to_string ~method_:"GET" ~url ~headers ~body
    in
    let bytes = Bytes.create 512 in
    let actual =
      Eta_http.H1.Write.write_to_bytes bytes ~pos:0 ~method_:"GET" ~url
        ~headers ~body
    in
    match (expected, actual) with
    | Ok expected, Ok len ->
        Alcotest.(check string)
          "bytes writer" expected (Bytes.sub_string bytes 0 len)
    | Error error, _ | _, Error error ->
        Alcotest.fail (Eta_http.Error.to_string error)

  let test_h1_writer_bytes_rejects_small_buffer () =
    let url = Eta_http.Core.Url.of_string "http://example.test/echo" in
    let bytes = Bytes.create 8 in
    match
      Eta_http.H1.Write.write_to_bytes bytes ~pos:0 ~method_:"GET" ~url
        ~headers:[] ~body:Eta_http.H1.Write.Empty
    with
    | Ok _ -> Alcotest.fail "small writer buffer unexpectedly succeeded"
    | Error { Eta_http.Error.kind = Header_invalid { reason }; _ } ->
        Alcotest.(check string) "small buffer error" "request buffer too small"
          reason
    | Error error -> Alcotest.fail (Eta_http.Error.to_string error)

  let h1_injection_cases =
    [
      ("value CRLF", [ ("X-Good", "ok\r\ninjected: 1") ]);
      ("name CRLF", [ ("x-good\r\ninjected", "1") ]);
      ("value LF", [ ("X-Good", "ok\ninjected: 1") ]);
      ("value CR", [ ("X-Good", "ok\rinjected: 1") ]);
      ("value obs-fold", [ ("X-Good", "ok\n injected: 1") ]);
      ("name NUL", [ ("x\000bad", "1") ]);
      ("value NUL", [ ("X-Good", "bad\000value") ]);
    ]

  let expect_h1_header_invalid label = function
    | Error { Eta_http.Error.kind = Header_invalid _; _ } -> ()
    | Error error ->
        Alcotest.failf "%s unexpected error: %s" label
          (Eta_http.Error.to_string error)
    | Ok wire ->
        Alcotest.(check bool)
          (label ^ " injected line absent")
          false
          (contains wire "injected: 1");
        Alcotest.failf "%s unexpectedly accepted invalid header" label

  let expect_h1_header_invalid_len label bytes = function
    | Error { Eta_http.Error.kind = Header_invalid _; _ } -> ()
    | Error error ->
        Alcotest.failf "%s unexpected error: %s" label
          (Eta_http.Error.to_string error)
    | Ok len ->
        let wire = Bytes.sub_string bytes 0 len in
        Alcotest.(check bool)
          (label ^ " injected line absent")
          false
          (contains wire "injected: 1");
        Alcotest.failf "%s unexpectedly accepted invalid header" label

  let test_h1_writer_rejects_header_injection () =
    let url = Eta_http.Core.Url.of_string "http://example.test/injection" in
    List.iter
      (fun (label, headers) ->
        Eta_http.H1.Write.to_string ~method_:"GET" ~url ~headers
          ~body:Eta_http.H1.Write.Empty
        |> expect_h1_header_invalid (label ^ " string");
        let bytes = Bytes.create 512 in
        Eta_http.H1.Write.write_to_bytes bytes ~pos:0 ~method_:"GET" ~url
          ~headers ~body:Eta_http.H1.Write.Empty
        |> expect_h1_header_invalid_len (label ^ " bytes") bytes)
      h1_injection_cases

  module H2_multiplexer = H2_multiplexer_suites.Make (B)
  module Server = Server_common_suites.Make (B)

  let tests =
    [
      ( "core",
        [
          Alcotest.test_case "loads" `Quick test_skeleton_loads;
          Alcotest.test_case "header value accepts HTAB" `Quick
            test_header_value_accepts_htab;
          Alcotest.test_case "method parsing preserves semantics" `Quick
            test_method_of_string_fast_path_semantics;
          Alcotest.test_case "error redaction and projection" `Quick
            test_error_redaction_and_projection;
          Alcotest.test_case "trace context request helpers" `Quick
            test_trace_context_request_helpers;
        ] );
      ( "url",
        [
          Alcotest.test_case "client subset" `Quick test_url_parse_client_subset;
          Alcotest.test_case "reject unsupported forms" `Quick
            test_url_rejects_unsupported_forms;
          Alcotest.test_case "fragment question mark is not query" `Quick
            test_url_fragment_question_mark_not_query;
          Alcotest.test_case "IPv6 authority brackets" `Quick
            test_url_ipv6_authority_restores_brackets;
        ] );
      ( "retry",
        [
          Alcotest.test_case "idempotency classifier" `Quick
            test_idempotency_classifier;
          Alcotest.test_case "Retry-After parser" `Quick test_retry_after_parser;
          Alcotest.test_case "retry policy classification" `Quick
            test_retry_policy_classification;
          Alcotest.test_case "Retry-After overflow delta ignored" `Quick
            test_retry_after_overflow_delta_seconds_is_ignored;
          Alcotest.test_case "Retry-After rejects impossible date" `Quick
            test_retry_after_rejects_impossible_http_date;
          Alcotest.test_case "Retry-After absolute date uses clock" `Quick
            test_retry_after_absolute_date_uses_clock;
          Alcotest.test_case "Retry-After overflow falls back" `Quick
            test_retry_policy_overflow_retry_after_falls_back_to_schedule;
          Alcotest.test_case "Retry-After overflow date falls back" `Quick
            test_retry_policy_overflow_retry_after_date_falls_back_to_schedule;
          Alcotest.test_case "rejects invalid max_attempts" `Quick
            test_retry_policy_rejects_invalid_max_attempts;
          Alcotest.test_case "max_attempts one does not retry" `Quick
            test_retry_policy_max_attempts_one_does_not_retry;
          Alcotest.test_case "custom status classifier" `Quick
            test_retry_policy_custom_status_classifier;
          Alcotest.test_case "always requires replayable body" `Quick
            test_retry_always_still_requires_replayable_body;
          Alcotest.test_case "succeeds on third attempt" `Quick
            test_retry_succeeds_on_third_attempt;
          Alcotest.test_case "non-idempotent requires opt-in" `Quick
            test_retry_non_idempotent_requires_opt_in;
        ] );
      ( "observability",
        [
          Alcotest.test_case "successful GET semconv" `Quick
            test_observability_success_get_semconv;
          Alcotest.test_case "redacts URL query by default" `Quick
            test_observability_redacts_url_query_by_default;
          Alcotest.test_case "can emit raw url.full" `Quick
            test_observability_can_emit_raw_url_full;
          Alcotest.test_case "DNS error semconv" `Quick
            test_observability_dns_error_semconv;
          Alcotest.test_case "TLS error semconv" `Quick
            test_observability_tls_error_semconv;
          Alcotest.test_case "retry success spans" `Quick
            test_observability_retry_success_spans;
          Alcotest.test_case "redirect semconv" `Quick
            test_observability_redirect_semconv;
          Alcotest.test_case "redirect semconv raw opt-in" `Quick
            test_observability_redirect_semconv_can_emit_raw;
          Alcotest.test_case "h2 protocol attrs" `Quick
            test_observability_h2_protocol_attrs;
          Alcotest.test_case "recursion disabled" `Quick
            test_observability_recursion_disabled;
          Alcotest.test_case "recursion disabled suppresses inner spans" `Quick
            test_observability_recursion_disabled_suppresses_inner_spans;
          Alcotest.test_case "pool stats meter" `Quick
            test_observability_pool_stats_meter;
        ] );
      ( "ws-codec",
        [
          Alcotest.test_case "accept key vector" `Quick
            test_ws_accept_key_vector;
          Alcotest.test_case "masked text roundtrip" `Quick
            test_ws_codec_masked_text_roundtrip;
          Alcotest.test_case "rejects one-byte close payload" `Quick
            test_ws_codec_rejects_one_byte_close_payload;
          Alcotest.test_case "rejects encoded one-byte close payload" `Quick
            test_ws_codec_rejects_encoded_one_byte_close_payload;
          Alcotest.test_case "rejects invalid close status codes" `Quick
            test_ws_codec_rejects_invalid_close_status_codes;
          Alcotest.test_case "encoder rejects invalid close status code" `Quick
            test_ws_codec_encoder_rejects_invalid_close_status_code;
          Alcotest.test_case "random material avoids Stdlib.Random" `Quick
            test_ws_random_material_does_not_use_stdlib_random;
          Alcotest.test_case "accept key does not own SHA-1" `Quick
            test_ws_accept_key_does_not_own_sha1;
        ] );
      ( "h2-admission",
        [
          Alcotest.test_case "cancelled counts until release" `Quick
            test_h2_admission_counts_cancelled_until_release;
        ] );
      ( "h2-stream-state",
        [
          Alcotest.test_case "release decisions" `Quick
            test_h2_stream_state_release_decisions;
          Alcotest.test_case "close releases live state" `Quick
            test_h2_stream_state_close_releases_live_state;
        ] );
      ( "h2-frame",
        [
          Alcotest.test_case "parse header" `Quick test_h2_frame_parse_header;
          Alcotest.test_case "uint32 rejects overflow" `Quick
            test_h2_frame_uint32_rejects_overflow;
        ] );
      ( "h2-writer",
        [
          Alcotest.test_case "preserves iovec slices" `Quick
            test_h2_writer_preserves_iovec_slices;
        ] );
      ( "h2-security",
        [
          Alcotest.test_case "HPACK block cap" `Quick
            test_h2_security_hpack_block_cap;
          Alcotest.test_case "CONTINUATION cap" `Quick
            test_h2_security_continuation_cap;
          Alcotest.test_case "initial HEADERS fragment cap" `Quick
            test_h2_security_rejects_oversized_initial_headers_fragment;
          Alcotest.test_case "PUSH_PROMISE fragment cap" `Quick
            test_h2_security_rejects_oversized_push_promise_fragment;
          Alcotest.test_case "GOAWAY churn" `Quick
            test_h2_security_goaway_churn;
          Alcotest.test_case "SETTINGS churn" `Quick
            test_h2_security_settings_churn;
          Alcotest.test_case "RST churn" `Quick test_h2_security_rst_churn;
          Alcotest.test_case "PING churn" `Quick test_h2_security_ping_churn;
          Alcotest.test_case "header churn" `Quick
            test_h2_security_header_churn;
          Alcotest.test_case "many normal response headers" `Quick
            test_h2_security_allows_many_normal_response_headers;
          Alcotest.test_case "forgets completed stream headers" `Quick
            test_h2_security_forgets_completed_stream_headers;
          Alcotest.test_case "multiplexer release forgets stream headers" `Quick
            test_h2_security_multiplexer_release_forgets_stream_headers;
          Alcotest.test_case "header normalization edges" `Quick
            test_h2_security_header_normalization_edges;
        ] );
      ( "alpn",
        [
          Alcotest.test_case "auto client uses dispatch state" `Quick
            test_auto_client_uses_alpn_dispatch_state;
          Alcotest.test_case "pending first-arrivals collapse" `Quick
            test_alpn_state_collapses_pending_first_arrivals;
          Alcotest.test_case "stale resolution and decode" `Quick
            test_alpn_state_ignores_stale_resolution_and_decodes_protocols;
        ] );
      ( "dispatch",
        [
          Alcotest.test_case "ALPN route decision" `Quick
            test_dispatch_decides_alpn_route;
        ] );
      ( "tls",
        [
          Alcotest.test_case "chokepoint policy" `Quick
            test_tls_chokepoint_policy;
        ] );
      ( "body",
        [
          Alcotest.test_case "release once" `Quick
            test_body_stream_release_once;
          Alcotest.test_case "reader release once" `Quick
            test_body_stream_reader_release_once;
          Alcotest.test_case "rejects concurrent reads" `Quick
            test_body_stream_rejects_concurrent_reads;
          Alcotest.test_case "source owned stream release" `Quick
            test_body_source_owned_stream_releases_on_scope_exit;
          Alcotest.test_case "source rewindable stream ownership" `Quick
            test_body_source_rewindable_stream_is_owned_per_call;
          Alcotest.test_case "read_all caps default" `Quick
            test_body_stream_read_all_caps_default;
          Alcotest.test_case "chunked trailers" `Quick
            test_chunked_decodes_trailers;
          Alcotest.test_case "chunked rejects invalid trailer header" `Quick
            test_chunked_decoder_rejects_invalid_trailer_header;
          Alcotest.test_case "chunked rejects oversized trailers" `Quick
            test_chunked_decoder_rejects_oversized_trailers;
          Alcotest.test_case "chunked rejects too many trailers" `Quick
            test_chunked_decoder_rejects_too_many_trailers;
          Alcotest.test_case "chunked encoder" `Quick test_chunked_encoder;
          Alcotest.test_case "chunked encoder rejects invalid trailers" `Quick
            test_chunked_encoder_rejects_invalid_trailers;
          Alcotest.test_case "chunked decoder rejects forbidden trailer" `Quick
            test_chunked_decoder_rejects_forbidden_content_length_trailer;
          Alcotest.test_case "chunked encoder rejects forbidden trailer" `Quick
            test_chunked_encoder_rejects_forbidden_content_length_trailer;
          Alcotest.test_case "gzip roundtrip" `Quick
            test_gzip_transducer_roundtrip;
          Alcotest.test_case "gzip expansion cap" `Quick
            test_gzip_transducer_expansion_cap;
          Alcotest.test_case "gzip truncated stream" `Quick
            test_gzip_transducer_rejects_truncated_stream;
          Alcotest.test_case "gzip CRC mismatch" `Quick
            test_gzip_transducer_rejects_crc_mismatch;
          Alcotest.test_case "gzip concatenated members" `Quick
            test_gzip_transducer_decodes_concatenated_members;
        ] );
      ( "h1-parse",
        [
          Alcotest.test_case "fixed body" `Quick test_h1_parser_fixed_body;
          Alcotest.test_case "no body response" `Quick
            test_h1_parser_no_body_head;
          Alcotest.test_case "bad content length" `Quick
            test_h1_parser_rejects_bad_content_length;
          Alcotest.test_case "conflicting content length" `Quick
            test_h1_parser_rejects_conflicting_content_length;
          Alcotest.test_case "invalid header value controls" `Quick
            test_h1_parser_rejects_invalid_header_value_controls;
          Alcotest.test_case "request head" `Quick
            test_h1_request_parser_request_head;
          Alcotest.test_case "partial request" `Quick
            test_h1_request_parser_partial;
          Alcotest.test_case "request limits" `Quick
            test_h1_request_parser_rejects_limits;
          Alcotest.test_case "invalid request syntax" `Quick
            test_h1_request_parser_rejects_invalid_syntax;
        ] );
      ( "h1-request-body",
        [
          Alcotest.test_case "no body and fixed" `Quick
            test_h1_request_body_framing_no_body_and_fixed;
          Alcotest.test_case "rejects Content-Length errors" `Quick
            test_h1_request_body_framing_rejects_content_length;
          Alcotest.test_case "rejects Transfer-Encoding errors" `Quick
            test_h1_request_body_framing_rejects_transfer_encoding;
          Alcotest.test_case "chunked trailers" `Quick
            test_h1_request_body_framing_chunked_trailers;
        ] );
      ( "h1-response-write",
        [
          Alcotest.test_case "fixed body" `Quick
            test_h1_response_writer_fixed_body;
          Alcotest.test_case "HEAD and no-body status" `Quick
            test_h1_response_writer_head_and_no_body_status;
          Alcotest.test_case "stream length" `Quick
            test_h1_response_writer_stream_length;
          Alcotest.test_case "chunked stream and trailers" `Quick
            test_h1_response_writer_chunked_stream_and_trailers;
          Alcotest.test_case "HTTP/1.0 close-delimited stream" `Quick
            test_h1_response_writer_http10_close_delimited_stream;
          Alcotest.test_case "rejects caller framing headers" `Quick
            test_h1_response_writer_rejects_caller_framing_headers;
          Alcotest.test_case "rejects hop-by-hop headers" `Quick
            test_h1_response_writer_rejects_hop_by_hop_headers;
          Alcotest.test_case "rejects Trailer without chunked body" `Quick
            test_h1_response_writer_rejects_trailer_without_chunked_body;
          Alcotest.test_case "rejects invalid Trailer names" `Quick
            test_h1_response_writer_rejects_invalid_trailer_names;
          Alcotest.test_case "rejects forbidden Trailer names" `Quick
            test_h1_response_writer_rejects_forbidden_trailer_names;
        ] );
      ( "h1-write",
        [
          Alcotest.test_case "GET origin-form" `Quick
            test_h1_writer_get_origin_form;
          Alcotest.test_case "fixed body" `Quick test_h1_writer_fixed_body;
          Alcotest.test_case "rejects mismatched Content-Length" `Quick
            test_h1_writer_rejects_mismatched_content_length;
          Alcotest.test_case "rejects invalid Content-Length framing" `Quick
            test_h1_writer_rejects_invalid_content_length_framing;
          Alcotest.test_case "rejects Transfer-Encoding fixed body" `Quick
            test_h1_writer_rejects_transfer_encoding_for_fixed_body;
          Alcotest.test_case "bytes matches string writer" `Quick
            test_h1_writer_bytes_matches_string_writer;
          Alcotest.test_case "bytes rejects small buffer" `Quick
            test_h1_writer_bytes_rejects_small_buffer;
          Alcotest.test_case "rejects header injection" `Quick
            test_h1_writer_rejects_header_injection;
        ] );
    ]
    @ Server.tests
    @ H2_multiplexer.tests
end
