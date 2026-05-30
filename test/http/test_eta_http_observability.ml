open Test_eta_http_support

let span_attr key span = List.assoc_opt key span.Eta.Tracer.attrs

let find_span name tracer =
  match List.filter (fun span -> String.equal span.Eta.Tracer.name name) (Eta.Tracer.dump tracer) with
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

let test_observability_success_get_semconv () =
  with_traced_test_clock @@ fun _sw _clock rt tracer ->
  let client =
    observability_client (fun _ -> Eta.Effect.pure (retry_response 200))
  in
  let request = Eta_http.Request.make "GET" "https://api.example.test:8443/a?b=c" in
  let response =
    Eta.Runtime.run rt (Eta_http.Observability.Tracer.request client request)
    |> Eta_test.Expect.expect_ok
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
  with_traced_test_clock @@ fun _sw _clock rt tracer ->
  let client =
    observability_client (fun _ -> Eta.Effect.pure (retry_response 200))
  in
  let request =
    Eta_http.Request.make "GET"
      "https://api.example.test/private?token=secret&email=a@example.test#frag"
  in
  ignore
    (Eta.Runtime.run rt (Eta_http.Observability.Tracer.request client request)
    |> Eta_test.Expect.expect_ok);
  let span = find_span "HTTP GET" tracer in
  Alcotest.(check (option string)) "redacted url"
    (Some "https://api.example.test/private?<redacted>#frag")
    (span_attr "url.full" span)

let test_observability_can_emit_raw_url_full () =
  with_traced_test_clock @@ fun _sw _clock rt tracer ->
  let client =
    observability_client (fun _ -> Eta.Effect.pure (retry_response 200))
  in
  let uri = "https://api.example.test/private?token=secret#frag" in
  let request = Eta_http.Request.make "GET" uri in
  ignore
    (Eta.Runtime.run rt
       (Eta_http.Observability.Tracer.request ~emit_url_full:true client request)
    |> Eta_test.Expect.expect_ok);
  let span = find_span "HTTP GET" tracer in
  Alcotest.(check (option string)) "raw url" (Some uri)
    (span_attr "url.full" span)

let test_observability_dns_error_semconv () =
  with_traced_test_clock @@ fun _sw _clock rt tracer ->
  let error =
    Eta_http.Error.make ~method_:"GET" ~uri:"https://missing.example.test/"
      (Dns_error { host = "missing.example.test"; message = "no such host" })
  in
  let client = observability_client (fun _ -> Eta.Effect.fail error) in
  let request = Eta_http.Request.make "GET" "https://missing.example.test/" in
  Eta_test.Expect.expect_typed_failure
    (Eta.Runtime.run rt (Eta_http.Observability.Tracer.request client request))
    (fun err ->
      match err.Eta_http.Error.kind with Dns_error _ -> true | _ -> false);
  let span = find_span "HTTP GET" tracer in
  Alcotest.(check (option string)) "error type" (Some "dns_error")
    (span_attr "error.type" span)

let test_observability_tls_error_semconv () =
  with_traced_test_clock @@ fun _sw _clock rt tracer ->
  let error =
    Eta_http.Error.make ~method_:"GET" ~uri:"https://expired.example.test/"
      (Tls_handshake_error
         { stage = Tls_handshake; message = "certificate expired" })
  in
  let client = observability_client (fun _ -> Eta.Effect.fail error) in
  let request = Eta_http.Request.make "GET" "https://expired.example.test/" in
  Eta_test.Expect.expect_typed_failure
    (Eta.Runtime.run rt (Eta_http.Observability.Tracer.request client request))
    (fun err ->
      match err.Eta_http.Error.kind with
      | Tls_handshake_error _ -> true
      | _ -> false);
  let span = find_span "HTTP GET" tracer in
  Alcotest.(check (option string)) "error type" (Some "tls_handshake_error")
    (span_attr "error.type" span)

let test_observability_retry_success_spans () =
  with_traced_test_clock @@ fun _sw _clock rt tracer ->
  let attempts, client =
    retry_client
      [|
        (fun () -> retry_response ~headers:[ "Retry-After", "0" ] 503);
        (fun () -> retry_response 200);
      |]
  in
  let request = Eta_http.Request.make "GET" "https://api.example.test/retry" in
  let response =
    Eta.Runtime.run rt
      (Eta_http.Observability.Tracer.request_with_retry client request)
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  Alcotest.(check int) "attempts" 2 !attempts;
  let spans = Eta.Tracer.dump tracer in
  Alcotest.(check bool) "parent span" true
    (List.exists (fun span -> String.equal span.Eta.Tracer.name "HTTP GET retry") spans);
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
  let attrs =
    Eta_http.Observability.Semconv.redirect_attrs ~location ()
  in
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
  with_traced_test_clock @@ fun _sw _clock rt tracer ->
  let client =
    observability_client ~protocol:Eta_http.Client.H2 (fun _ ->
        Eta.Effect.pure (retry_response 200))
  in
  let request = Eta_http.Request.make "GET" "https://api.example.test/h2" in
  ignore
    (Eta.Runtime.run rt
       (Eta_http.Observability.Tracer.request ~protocol:Eta_http.Client.H2 client
          request)
    |> Eta_test.Expect.expect_ok);
  let span = find_span "HTTP GET" tracer in
  Alcotest.(check (option string)) "h2" (Some "2")
    (span_attr "network.protocol.version" span)

let test_observability_recursion_disabled () =
  with_traced_test_clock @@ fun _sw _clock rt tracer ->
  let client =
    observability_client (fun _ -> Eta.Effect.pure (retry_response 200))
  in
  let request = Eta_http.Request.make "POST" "https://collector.example.test/v1/traces" in
  ignore
    (Eta.Runtime.run rt
       (Eta_http.Observability.Tracer.request ~enabled:false client request)
    |> Eta_test.Expect.expect_ok);
  Alcotest.(check int) "spans" 0 (List.length (Eta.Tracer.dump tracer))

let test_observability_recursion_disabled_suppresses_inner_spans () =
  with_traced_test_clock @@ fun _sw _clock rt tracer ->
  let client =
    observability_client (fun _ ->
        Eta.Effect.named "eta-http.internal"
          (Eta.Effect.pure (retry_response 200)))
  in
  let request = Eta_http.Request.make "POST" "https://collector.example.test/v1/traces" in
  ignore
    (Eta.Runtime.run rt
       (Eta_http.Observability.Tracer.request ~enabled:false client request)
    |> Eta_test.Expect.expect_ok);
  Alcotest.(check int) "spans" 0 (List.length (Eta.Tracer.dump tracer))

let test_observability_pool_stats_meter () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let meter = Eta.Meter.in_memory () in
  let rt =
    Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~meter:(Eta.Meter.as_capability meter) ()
  in
  let client =
    observability_client (fun _ -> Eta.Effect.pure (retry_response 200))
  in
  Eta.Runtime.run rt (Eta_http.Observability.Meter.record_client_stats client)
  |> Eta_test.Expect.expect_ok;
  let names = List.map (fun point -> point.Eta.Meter.name) (Eta.Meter.dump meter) in
  Alcotest.(check bool) "active metric" true
    (List.mem "eta_http.client.connections.active" names)
