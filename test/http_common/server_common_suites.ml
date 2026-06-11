module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  module Server = Eta_http.Server

  let run_ok rt eff =
    match B.run rt eff with
    | Eta.Exit.Ok value -> value
    | Eta.Exit.Error cause ->
        Alcotest.failf "expected Ok, got %a"
          (Eta.Cause.pp Server.Error.pp)
          cause

  let attr key attrs = List.assoc_opt key attrs

  let contains haystack needle =
    let h_len = String.length haystack in
    let n_len = String.length needle in
    let rec loop index =
      index + n_len <= h_len
      && (String.equal needle (String.sub haystack index n_len)
         || loop (index + 1))
    in
    n_len = 0 || loop 0

  let request ?(headers = Eta_http.Core.Header.empty) ?(target = "/items?token=1")
      ?(scheme = "http") ?(tls = false) ?(alpn_protocol = Some "h2c")
      ?stream_id () =
    let path, query = Server.Request.split_target target in
    {
      Server.Request.id = "req-1";
      version = Eta_http.Core.Version.H2;
      scheme;
      authority = Some "example.test";
      method_ = "get";
      target;
      path;
      query;
      headers;
      body = Server.Body.empty ();
      trailers = (fun () -> Eta.Effect.pure Eta_http.Core.Header.empty);
      peer = { address = Some "127.0.0.1"; port = Some 43123 };
      tls;
      alpn_protocol;
      stream_id;
      connection_id = "conn-1";
    }

  let response_body_string response =
    match Server.Response.body response with
    | Server.Response.Body.Fixed [ chunk ] -> Bytes.to_string chunk
    | Empty -> ""
    | Fixed chunks ->
        Bytes.to_string (Bytes.concat Bytes.empty chunks)
    | Stream _ -> Alcotest.fail "expected fixed response body"

  let test_error_status_projection_and_redaction () =
    let error =
      Server.Error.make ~protocol:H2c ~stream_id:7 ~method_:"POST"
        ~target:"/upload?token=secret"
        (Request_body_too_large { limit = 4; length = 5 })
    in
    Alcotest.(check (option int)) "status" (Some 413)
      (Server.Error.to_status error);
    Alcotest.(check string) "layer" "request_body"
      (Server.Error.layer_to_string (Server.Error.layer error));
    Alcotest.(check string) "class" "request_body_too_large"
      (Server.Error.error_class error);
    let projected = Server.Error.to_http_error error in
    (match projected.Eta_http.Error.kind with
    | Body_too_large { limit; length } ->
        Alcotest.(check int) "projected limit" 4 limit;
        Alcotest.(check int) "projected length" 5 length
    | _ -> Alcotest.fail "expected projected Body_too_large");
    let rendered = Server.Error.to_string error in
    Alcotest.(check bool) "redacted query" true
      (String.contains rendered '<');
    Alcotest.(check bool) "secret absent" false
      (contains rendered "secret");
    let h1_error =
      Server.Error.make ~protocol:H1 ~method_:"GET" ~target:"/bad"
        (Bad_request { message = "bad request line" })
    in
    Alcotest.(check string) "h1 protocol" "h1"
      (Server.Error.protocol_to_string h1_error.context.protocol);
    Alcotest.(check string) "projected h1 protocol" "h1"
      (Eta_http.Error.protocol_to_string
         (Server.Error.to_http_error h1_error).context.protocol);
    let expect_error =
      Server.Error.make ~protocol:H1 ~method_:"POST" ~target:"/upload"
        (Expectation_failed { expectation = "storage-quota" })
    in
    Alcotest.(check (option int)) "expect status" (Some 417)
      (Server.Error.to_status expect_error);
    Alcotest.(check string) "expect layer" "request_headers"
      (Server.Error.layer_to_string (Server.Error.layer expect_error));
    Alcotest.(check string) "expect class" "expectation_failed"
      (Server.Error.error_class expect_error);
    (match (Server.Error.to_http_error expect_error).kind with
    | Connection_protocol_violation { kind; message } ->
        Alcotest.(check string) "expect projected kind" "expectation_failed"
          kind;
        Alcotest.(check string) "expect projected message"
          "unsupported Expect header: storage-quota" message
    | _ -> Alcotest.fail "expected projected expectation protocol violation");
    let handler_timeout =
      Server.Error.make ~protocol:H2 ~stream_id:11 ~method_:"GET"
        ~target:"/slow"
        (Handler_timeout { timeout_ms = Some 20 })
    in
    Alcotest.(check (option int)) "handler timeout status" (Some 503)
      (Server.Error.to_status handler_timeout);
    Alcotest.(check string) "handler timeout layer" "handler"
      (Server.Error.layer_to_string (Server.Error.layer handler_timeout));
    Alcotest.(check string) "handler timeout class" "handler_timeout"
      (Server.Error.error_class handler_timeout);
    (match (Server.Error.to_http_error handler_timeout).kind with
    | Total_request_timeout { timeout_ms } ->
        Alcotest.(check (option int)) "handler timeout projection" (Some 20)
          timeout_ms
    | _ -> Alcotest.fail "expected projected handler timeout")

  let test_request_helpers_and_trace_context () =
    B.with_runtime @@ fun _ctx rt ->
    let trace_id = "4bf92f3577b34da6a3ce929d0e0e4736" in
    let span_id = "00f067aa0ba902b7" in
    let headers =
      Eta_http.Core.Header.unsafe_of_list
        [
          ("traceparent", "00-" ^ trace_id ^ "-" ^ span_id ^ "-01");
          ("x-extra", "1");
        ]
    in
    let req = request ~headers ~target:"/v1/search?q=secret" ~stream_id:11 () in
    Alcotest.(check string) "path" "/v1/search" req.path;
    Alcotest.(check (option string)) "query" (Some "q=secret") req.query;
    Alcotest.(check (option string)) "header" (Some "1")
      (Server.Request.header "x-extra" req);
    Alcotest.(check string) "connection id" "conn-1" req.connection_id;
    Alcotest.(check (list (pair string string))) "trailers" []
      (run_ok rt (Server.Request.trailers req));
    match Server.Request.trace_context req with
    | None -> Alcotest.fail "missing trace context"
    | Some ctx ->
        Alcotest.(check string) "trace id" trace_id ctx.trace_id;
        Alcotest.(check string) "span id" span_id ctx.span_id

  let test_body_read_all_and_release () =
    B.with_runtime @@ fun _ctx rt ->
    let released = ref 0 in
    let chunks = ref [ Bytes.of_string "he"; Bytes.of_string "llo" ] in
    let body =
      Server.Body.of_reader
        ~release:(fun () ->
          incr released;
          Eta.Effect.unit)
        (fun () ->
          match !chunks with
          | [] -> Eta.Effect.pure None
          | chunk :: rest ->
              chunks := rest;
              Eta.Effect.pure (Some chunk))
    in
    let value = run_ok rt (Server.Body.read_all body) in
    Alcotest.(check string) "body" "hello" (Bytes.to_string value);
    Alcotest.(check int) "release once" 1 !released;
    let eof = run_ok rt (Server.Body.read body) in
    Alcotest.(check bool) "eof after release" true (Option.is_none eof);
    Alcotest.(check int) "release still once" 1 !released

  let test_body_read_all_cap () =
    B.with_runtime @@ fun _ctx rt ->
    let body =
      Server.Body.of_reader
        (let done_ = ref false in
         fun () ->
           if !done_ then Eta.Effect.pure None
           else (
             done_ := true;
             Eta.Effect.pure (Some (Bytes.of_string "abcdef"))))
    in
    match B.run rt (Server.Body.read_all ~max_bytes:3 body) with
    | Eta.Exit.Ok _ -> Alcotest.fail "expected body cap failure"
    | Eta.Exit.Error
        (Eta.Cause.Fail
          { Server.Error.kind = Request_body_too_large { limit; length }; _ }) ->
        Alcotest.(check int) "limit" 3 limit;
        Alcotest.(check int) "length" 6 length
    | Eta.Exit.Error cause ->
        Alcotest.failf "unexpected failure: %a"
          (Eta.Cause.pp Server.Error.pp)
          cause

  let test_body_discard_passes_drain_policy () =
    B.with_runtime @@ fun _ctx rt ->
    let seen = ref None in
    let body =
      Server.Body.of_reader
        ~discard:(fun ~drain ->
          seen := Some drain;
          Eta.Effect.unit)
        (fun () -> Eta.Effect.pure (Some (Bytes.of_string "unread")))
    in
    run_ok rt (Server.Body.discard ~drain:true body);
    Alcotest.(check (option bool)) "drain" (Some true) !seen;
    run_ok rt (Server.Body.discard ~drain:false body);
    Alcotest.(check (option bool)) "discard once" (Some true) !seen

  let test_response_helpers_validate_and_preserve_body () =
    let response = Server.Response.text ~status:201 "created\n" in
    Alcotest.(check int) "status" 201 (Server.Response.status response);
    Alcotest.(check string) "body" "created\n" (response_body_string response);
    let stream =
      Server.Response.Body.stream ~length:7 (fun () -> Eta.Effect.pure None)
    in
    (match stream with
    | Server.Response.Body.Stream { length; _ } ->
        Alcotest.(check (option int)) "stream length" (Some 7) length
    | _ -> Alcotest.fail "expected stream response body");
    Alcotest.check_raises "invalid stream length"
      (Invalid_argument
         "Eta_http.Server.Response.Body.stream: length must be >= 0")
      (fun () ->
        ignore
          (Server.Response.Body.stream ~length:(-1) (fun () ->
               Eta.Effect.pure None)
            : Server.Response.Body.t));
    Alcotest.check_raises "invalid status" (Invalid_argument
      "Eta_http.Server.Response.make: status must be in the range 100..599")
      (fun () ->
        ignore (Server.Response.empty ~status:99 () : Server.Response.t))

  let test_server_config_defaults_and_validation () =
    let config = Server.Config.default in
    Alcotest.(check bool) "otel enabled" true config.enable_otel;
    Alcotest.(check bool) "url redaction default" false config.emit_url_full;
    Alcotest.(check int) "request header cap" (32 * 1024)
      config.limits.max_request_header_bytes;
    Alcotest.(check (option int)) "request body cap"
      (Some Eta_http.Body.Stream.default_max_bytes)
      config.limits.max_request_body_bytes;
    Server.Config.validate config;
    let invalid_drain =
      { config with unread_body_policy = Server.Config.Drain_up_to (-1) }
    in
    Alcotest.check_raises "invalid drain"
      (Invalid_argument "Eta_http.Server.Config.Drain_up_to must be >= 0")
      (fun () -> Server.Config.validate invalid_drain);
    let invalid_limits =
      {
        config with
        limits = { config.limits with max_request_headers = 0 };
      }
    in
    Alcotest.check_raises "invalid header count"
      (Invalid_argument
         "Eta_http.Server.Config.max_request_headers must be > 0")
      (fun () -> Server.Config.validate invalid_limits)

  let test_handler_helpers () =
    B.with_runtime @@ fun _ctx rt ->
    let error =
      Server.Error.make ~method_:"GET" ~target:"/bad"
        (Bad_request { message = "bad target" })
    in
    let handler _request = Eta.Effect.fail (`Bad error) in
    let handler =
      Server.Handler.map_error (function `Bad error -> error) handler
      |> Server.Handler.with_default_error_response
    in
    let response = run_ok rt (handler (request ~target:"/bad" ())) in
    Alcotest.(check int) "status" 400 (Server.Response.status response);
    Alcotest.(check string) "default body" "bad request\n"
      (response_body_string response)

  let test_server_semconv_redacts_query_by_default () =
    let attrs =
      Eta_http.Observability.Server.Semconv.request_attrs
        (request ~target:"/search?q=secret" ~stream_id:9 ())
    in
    Alcotest.(check (option string)) "method" (Some "GET")
      (attr "http.request.method" attrs);
    Alcotest.(check (option string)) "path" (Some "/search")
      (attr "url.path" attrs);
    Alcotest.(check (option string)) "query redacted" (Some "<redacted>")
      (attr "url.query.redacted" attrs);
    Alcotest.(check bool) "raw query absent" true
      (Option.is_none (attr "url.query" attrs));
    Alcotest.(check (option string)) "stream id" (Some "9")
      (attr "eta_http.server.stream_id" attrs);
    Alcotest.(check (option string)) "connection id" (Some "conn-1")
      (attr "eta_http.server.connection_id" attrs);
    Alcotest.(check (option string)) "tls" (Some "false")
      (attr "eta_http.server.tls" attrs);
    Alcotest.(check (option string)) "alpn" (Some "h2c")
      (attr "network.protocol.alpn" attrs);
    let tls_attrs =
      Eta_http.Observability.Server.Semconv.request_attrs
        (request ~scheme:"https" ~tls:true ~alpn_protocol:(Some "h2")
           ~target:"/secure" ())
    in
    Alcotest.(check (option string)) "tls true" (Some "true")
      (attr "eta_http.server.tls" tls_attrs);
    Alcotest.(check (option string)) "tls alpn" (Some "h2")
      (attr "network.protocol.alpn" tls_attrs)

  let test_server_tracer_span_kind_attrs_and_parent () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let trace_id = "4bf92f3577b34da6a3ce929d0e0e4736" in
    let span_id = "00f067aa0ba902b7" in
    let headers =
      Eta_http.Core.Header.unsafe_of_list
        [ ("traceparent", "00-" ^ trace_id ^ "-" ^ span_id ^ "-01") ]
    in
    let req =
      request ~headers ~target:"/healthz?token=secret" ~scheme:"https"
        ~tls:true ~alpn_protocol:(Some "h2") ()
    in
    let handler _request = Eta.Effect.pure (Server.Response.text "ok\n") in
    let response =
      run_ok rt (Eta_http.Observability.Server.Tracer.request handler req)
    in
    Alcotest.(check int) "status" 200 (Server.Response.status response);
    match Eta.Tracer.dump tracer with
    | [ span ] ->
        Alcotest.(check bool) "server kind" true
          (span.Eta.Tracer.kind = Eta.Tracer.Server);
        Alcotest.(check string) "span name" "HTTP GET" span.name;
        Alcotest.(check (option string)) "path attr" (Some "/healthz")
          (attr "url.path" span.attrs);
        Alcotest.(check (option string)) "query redacted"
          (Some "<redacted>") (attr "url.query.redacted" span.attrs);
        Alcotest.(check (option string)) "tls attr" (Some "true")
          (attr "eta_http.server.tls" span.attrs);
        Alcotest.(check (option string)) "alpn attr" (Some "h2")
          (attr "network.protocol.alpn" span.attrs);
        (match span.external_parent with
        | None -> Alcotest.fail "missing external parent"
        | Some parent ->
            Alcotest.(check string) "parent trace id" trace_id parent.trace_id;
            Alcotest.(check string) "parent span id" span_id parent.span_id)
    | spans -> Alcotest.failf "expected one span, got %d" (List.length spans)

  let tests =
    [
      ( "server",
        [
          Alcotest.test_case "error status/projection/redaction" `Quick
            test_error_status_projection_and_redaction;
          Alcotest.test_case "request helpers and trace context" `Quick
            test_request_helpers_and_trace_context;
          Alcotest.test_case "body read_all and release" `Quick
            test_body_read_all_and_release;
          Alcotest.test_case "body read_all cap" `Quick test_body_read_all_cap;
          Alcotest.test_case "body discard drain policy" `Quick
            test_body_discard_passes_drain_policy;
          Alcotest.test_case "response helpers" `Quick
            test_response_helpers_validate_and_preserve_body;
          Alcotest.test_case "config defaults and validation" `Quick
            test_server_config_defaults_and_validation;
          Alcotest.test_case "handler helpers" `Quick test_handler_helpers;
          Alcotest.test_case "semconv redacts query" `Quick
            test_server_semconv_redacts_query_by_default;
          Alcotest.test_case "tracer span kind and parent" `Quick
            test_server_tracer_span_kind_attrs_and_parent;
        ] );
    ]
end
