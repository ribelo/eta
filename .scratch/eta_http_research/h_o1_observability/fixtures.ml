open Eta

module Http = Eta_http_stub
module S = Semconv

type capture = {
  result : (Http.response, Error.t) Exit.t;
  spans : Tracer.span list;
  metrics : Meter.point list;
  logs : Logger.record list;
}

let fail msg = failwith msg

let check label cond =
  if cond then Printf.printf "PASS %s\n%!" label else fail ("FAIL " ^ label)

let parent_context =
  match
    Trace_context.make
      ~trace_id:"11111111111111111111111111111111"
      ~span_id:"2222222222222222"
      ~trace_state:[ ("rojo", "00") ]
      ~baggage:[ ("tenant", "eta") ] ()
  with
  | Some ctx -> ctx
  | None -> failwith "invalid parent trace context"

let run_capture effect =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let meter = Meter.in_memory () in
  let logger = Logger.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ~meter:(Meter.as_capability meter)
      ~logger:(Logger.as_capability logger) ()
  in
  let result = Runtime.run rt (Effect.with_context parent_context effect) in
  Runtime.drain rt;
  {
    result;
    spans = Tracer.dump tracer;
    metrics = Meter.dump meter;
    logs = Logger.dump logger;
  }

let response = function
  | Exit.Ok response -> response
  | Exit.Error cause ->
      Format.eprintf "unexpected failure: %a\n%!"
        (Cause.pp (fun fmt err -> Format.pp_print_string fmt (Error.to_string err)))
        cause;
      fail "expected success"

let expect_error = function
  | Exit.Error _ -> ()
  | Exit.Ok _ -> fail "expected error"

let find_span name spans = List.find_opt (fun span -> span.Tracer.name = name) spans

let spans_named name spans = List.filter (fun span -> span.Tracer.name = name) spans

let attr key span = List.assoc_opt key span.Tracer.attrs

let has_metric name metrics = List.exists (fun p -> p.Meter.name = name) metrics

let has_log body logs = List.exists (fun r -> r.Logger.body = body) logs

let traceparent response span =
  match List.assoc_opt "traceparent" response.Http.injected_headers with
  | Some value -> String.starts_with ~prefix:("00-" ^ span.Tracer.trace_id ^ "-") value
  | None -> false

let test_successful_get () =
  let cap = run_capture (Http.request Successful_get) in
  let res = response cap.result in
  let span = Option.get (find_span "GET" cap.spans) in
  check "successful GET returns 200" (res.status = Some 200);
  check "successful GET has one client span"
    (List.length cap.spans = 1 && span.kind = Capabilities.Client);
  check "successful GET semconv attrs"
    (attr S.http_request_method span = Some "GET"
    && attr S.url_full span = Some "https://api.example.test/widgets?debug=true"
    && attr S.server_address span = Some "api.example.test"
    && attr S.network_protocol_version span = Some "1.1"
    && attr S.http_response_status_code span = Some "200");
  check "W3C trace context injected from active client span" (traceparent res span);
  check "successful GET emits HTTP metrics"
    (has_metric S.metric_request_duration cap.metrics
    && has_metric S.metric_active_requests cap.metrics
    && has_metric S.metric_request_body_size cap.metrics
    && has_metric S.metric_response_body_size cap.metrics)

let test_connect_error () =
  let cap = run_capture (Http.request Connect_error) in
  expect_error cap.result;
  let span = Option.get (find_span "GET" cap.spans) in
  check "connect error marks span error"
    (span.status <> Capabilities.Ok && attr S.error_type span = Some "connect_timeout");
  check "connect error emits log" (has_log "eta-http connect error" cap.logs)

let test_tls_errors () =
  let cert = run_capture (Http.request Tls_certificate_error) in
  let handshake = run_capture (Http.request Tls_handshake_error) in
  expect_error cert.result;
  expect_error handshake.result;
  let cert_span = Option.get (find_span "GET" cert.spans) in
  let handshake_span = Option.get (find_span "GET" handshake.spans) in
  check "TLS certificate error attrs"
    (attr S.error_type cert_span = Some "tls_certificate_error"
    && cert_span.status <> Capabilities.Ok);
  check "TLS handshake error attrs"
    (attr S.error_type handshake_span = Some "tls_handshake_error"
    && handshake_span.status <> Capabilities.Ok);
  check "TLS errors emit logs"
    (has_log "eta-http tls error" cert.logs
    && has_log "eta-http tls error" handshake.logs)

let test_retry () =
  let cap = run_capture (Http.request Http_500_retry) in
  let res = response cap.result in
  let parent = Option.get (find_span "GET" cap.spans) in
  let children = spans_named "GET retry" cap.spans in
  check "HTTP 500 retry succeeds on attempt 2"
    (res.status = Some 200 && res.attempts = 2);
  check "retry parent and child spans"
    (List.length children = 2 && attr S.http_request_resend_count parent = Some "1");
  check "first retry child records 500 error"
    (List.exists
       (fun span ->
         attr S.http_response_status_code span = Some "500"
         && span.Tracer.status <> Capabilities.Ok)
       children);
  check "retry decision logged" (has_log "eta-http retry decision" cap.logs)

let test_redirect () =
  let cap = run_capture (Http.request Redirect_chain) in
  let res = response cap.result in
  let redirects = spans_named "GET redirect" cap.spans in
  check "redirect chain lands on 200" (res.status = Some 200 && res.redirects = 1);
  check "redirect child spans carry 301 and 200"
    (List.exists (fun span -> attr S.http_response_status_code span = Some "301") redirects
    && List.exists (fun span -> attr S.http_response_status_code span = Some "200") redirects);
  check "redirect event logged" (has_log "eta-http redirect" cap.logs)

let test_h2_request () =
  let cap = run_capture (Http.request H2_request) in
  let res = response cap.result in
  let span = Option.get (find_span "GET" cap.spans) in
  check "h2 request returns 200" (res.status = Some 200);
  check "h2 semconv protocol differs from h1"
    (attr S.network_protocol_version span = Some "2")

let () =
  test_successful_get ();
  test_connect_error ();
  test_tls_errors ();
  test_retry ();
  test_redirect ();
  test_h2_request ();
  Printf.printf "h_o1_observability fixtures passed (semconv %s)\n%!" S.version
