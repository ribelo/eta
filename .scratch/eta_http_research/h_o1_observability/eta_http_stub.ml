open Eta

module S = Semconv

type protocol = [ `H1 | `H2 ]

type scenario =
  | Successful_get
  | Connect_error
  | Tls_certificate_error
  | Tls_handshake_error
  | Http_500_retry
  | Redirect_chain
  | H2_request
  | Otlp_export

type config = {
  suppress_client_spans : bool;
  pool_active : int;
  pool_idle : int;
}

type response = {
  status : int option;
  attempts : int;
  redirects : int;
  injected_headers : (string * string) list;
}

let default_config = { suppress_client_spans = false; pool_active = 1; pool_idle = 3 }

let ( let* ) effect f = Effect.bind f effect

let seq effects =
  List.fold_left
    (fun acc effect -> acc |> Effect.bind (fun () -> effect))
    Effect.unit effects

let error_protocol = function `H1 -> Error.H1 | `H2 -> Error.H2

let http_error ~protocol ~method_ ~url kind =
  Error.make ~protocol:(error_protocol protocol) ~method_ ~uri:url kind

let annotate_all attrs body =
  List.fold_left
    (fun effect (key, value) -> Effect.annotate ~key ~value effect)
    body attrs

let with_client_span config ~name ~attrs body =
  if config.suppress_client_spans then body
  else
    Effect.named_kind ~kind:Capabilities.Client ~error_renderer:Error.to_string
      name (annotate_all attrs body)

let metric ?(description = "") ?(unit_ = "") ~name ~kind ~attrs value =
  Effect.metric_update ~description ~unit_ ~attrs ~name ~kind value

let gauge_int ~name ~unit_ ~attrs value =
  metric ~name ~unit_ ~kind:Capabilities.Gauge ~attrs (Capabilities.Int value)

let gauge_float ~name ~unit_ ~attrs value =
  metric ~name ~unit_ ~kind:Capabilities.Gauge ~attrs (Capabilities.Float value)

let active_scope attrs body =
  Effect.scoped
    (Effect.acquire_release
       ~acquire:(gauge_int ~name:S.metric_active_requests ~unit_:"{request}" ~attrs 1)
       ~release:(fun () ->
         gauge_int ~name:S.metric_active_requests ~unit_:"{request}" ~attrs 0)
    |> Effect.bind (fun () -> body))

let pool_metrics config attrs =
  seq
    [
      gauge_int ~name:S.metric_pool_active ~unit_:"{connection}" ~attrs
        config.pool_active;
      gauge_int ~name:S.metric_pool_idle ~unit_:"{connection}" ~attrs
        config.pool_idle;
    ]

let success_metrics config attrs ~request_bytes ~response_bytes =
  seq
    [
      gauge_float ~name:S.metric_request_duration ~unit_:"s" ~attrs 0.012;
      gauge_int ~name:S.metric_request_body_size ~unit_:"By" ~attrs request_bytes;
      gauge_int ~name:S.metric_response_body_size ~unit_:"By" ~attrs response_bytes;
      pool_metrics config attrs;
    ]

let inject_current_context =
  Effect.current_context
  |> Effect.map (function None -> [] | Some ctx -> Trace_context.inject ctx)

let log ?(level = Capabilities.Info) body attrs = Effect.log ~level ~attrs body

let ok_response ?(attempts = 1) ?(redirects = 0) status injected_headers =
  { status = Some status; attempts; redirects; injected_headers }

let run_success config ~method_ ~url ~protocol ~status ~request_bytes
    ~response_bytes =
  let base = S.base_http_attrs ~method_ ~url ~protocol in
  let attrs = S.with_status status base in
  with_client_span config ~name:method_ ~attrs
    (active_scope base
       (let* injected_headers = inject_current_context in
        let* () = success_metrics config attrs ~request_bytes ~response_bytes in
        Effect.pure (ok_response status injected_headers)))

let run_connect_error config =
  let method_ = "GET" in
  let url = "https://api.example.test/widgets" in
  let protocol = `H1 in
  let base = S.base_http_attrs ~method_ ~url ~protocol in
  let attrs = S.with_error "connect_timeout" base in
  let err =
    http_error ~protocol ~method_ ~url
      (Connect_timeout { timeout_ms = Some 1_000 })
  in
  with_client_span config ~name:method_ ~attrs
    (active_scope base
       (let* _ = inject_current_context in
        let* () =
          log ~level:Capabilities.Error "eta-http connect error"
            [
              ("event.name", "connect.error");
              (S.error_type, "connect_timeout");
              ("server.address", "api.example.test");
            ]
        in
        let* () =
          gauge_float ~name:S.metric_request_duration ~unit_:"s" ~attrs 1.0
        in
        Effect.fail err))

let run_tls_error config ~kind_name ~kind =
  let method_ = "GET" in
  let url = "https://tls.example.test/secure" in
  let protocol = `H1 in
  let base = S.base_http_attrs ~method_ ~url ~protocol in
  let attrs = S.with_error kind_name base in
  let err = http_error ~protocol ~method_ ~url kind in
  with_client_span config ~name:method_ ~attrs
    (active_scope base
       (let* _ = inject_current_context in
        let* () =
          log ~level:Capabilities.Error "eta-http tls error"
            [
              ("event.name", "tls.error");
              (S.error_type, kind_name);
              ("tls.stage", kind_name);
            ]
        in
        let* () =
          gauge_float ~name:S.metric_request_duration ~unit_:"s" ~attrs 0.2
        in
        Effect.fail err))

let retry_child_error config ~method_ ~url ~protocol =
  let base = S.base_http_attrs ~method_ ~url ~protocol in
  let attrs = base |> S.with_status 500 |> S.with_resend 0 |> S.with_error "http_status_5xx" in
  let err =
    http_error ~protocol ~method_ ~url
      (HTTP_status { status = 500; headers = [ ("retry-after", "0") ] })
  in
  with_client_span config ~name:(method_ ^ " retry") ~attrs (Effect.fail err)
  |> Effect.catch (fun _ -> Effect.unit)

let retry_child_success config ~method_ ~url ~protocol =
  let base = S.base_http_attrs ~method_ ~url ~protocol in
  let attrs = base |> S.with_status 200 |> S.with_resend 1 in
  with_client_span config ~name:(method_ ^ " retry") ~attrs Effect.unit

let run_retry config =
  let method_ = "GET" in
  let url = "https://api.example.test/retry" in
  let protocol = `H1 in
  let base = S.base_http_attrs ~method_ ~url ~protocol in
  let parent_attrs = base |> S.with_status 200 |> S.with_resend 1 in
  with_client_span config ~name:method_ ~attrs:parent_attrs
    (active_scope base
       (let* injected_headers = inject_current_context in
        let* () = retry_child_error config ~method_ ~url ~protocol in
        let* () =
          log "eta-http retry decision"
            [
              ("event.name", "retry.decision");
              ("retry.reason", "http_status_5xx");
              (S.http_request_resend_count, "1");
            ]
        in
        let* () = retry_child_success config ~method_ ~url ~protocol in
        let* () = success_metrics config parent_attrs ~request_bytes:0 ~response_bytes:2 in
        Effect.pure (ok_response ~attempts:2 200 injected_headers)))

let redirect_child config ~method_ ~url ~protocol ~status ~resend =
  let attrs =
    S.base_http_attrs ~method_ ~url ~protocol |> S.with_status status
    |> S.with_resend resend
  in
  with_client_span config ~name:(method_ ^ " redirect") ~attrs Effect.unit

let run_redirect config =
  let method_ = "GET" in
  let first_url = "https://api.example.test/old" in
  let final_url = "https://api.example.test/new" in
  let protocol = `H1 in
  let base = S.base_http_attrs ~method_ ~url:final_url ~protocol in
  let parent_attrs = base |> S.with_status 200 |> S.with_resend 1 in
  with_client_span config ~name:method_ ~attrs:parent_attrs
    (active_scope base
       (let* injected_headers = inject_current_context in
        let* () =
          redirect_child config ~method_ ~url:first_url ~protocol ~status:301
            ~resend:0
        in
        let* () =
          log "eta-http redirect"
            [
              ("event.name", "redirect");
              ("http.response.status_code", "301");
              ("url.full", final_url);
            ]
        in
        let* () =
          redirect_child config ~method_ ~url:final_url ~protocol ~status:200
            ~resend:1
        in
        let* () = success_metrics config parent_attrs ~request_bytes:0 ~response_bytes:3 in
        Effect.pure (ok_response ~redirects:1 200 injected_headers)))

let request ?(config = default_config) scenario =
  match scenario with
  | Successful_get ->
      run_success config ~method_:"GET"
        ~url:"https://api.example.test/widgets?debug=true" ~protocol:`H1
        ~status:200 ~request_bytes:0 ~response_bytes:5
  | Connect_error -> run_connect_error config
  | Tls_certificate_error ->
      run_tls_error config ~kind_name:"tls_certificate_error"
        ~kind:
          (Tls_certificate_error
             { reason = Expired; message = "certificate expired" })
  | Tls_handshake_error ->
      run_tls_error config ~kind_name:"tls_handshake_error"
        ~kind:
          (Tls_handshake_error
             { stage = Tls_handshake; message = "handshake failed" })
  | Http_500_retry -> run_retry config
  | Redirect_chain -> run_redirect config
  | H2_request ->
      run_success config ~method_:"GET" ~url:"https://api.example.test/h2"
        ~protocol:`H2 ~status:200 ~request_bytes:0 ~response_bytes:2
  | Otlp_export ->
      run_success config ~method_:"POST"
        ~url:"http://collector.example.test/v1/traces" ~protocol:`H1
        ~status:200 ~request_bytes:512 ~response_bytes:0
