type endpoint_class =
  | Otlp_collector
  | Llm_provider
  | Cdn_reference

type target = {
  name : string;
  endpoint_class : endpoint_class;
  url : string;
  host : string;
  service : string;
  rationale : string;
}

type outcome =
  | Handshake_ok of {
      version : string;
      alpn : string option;
      cipher : string;
    }
  | Handshake_error of string

let narrowed_ciphers =
  [
    `ECDHE_RSA_WITH_AES_128_GCM_SHA256;
    `ECDHE_RSA_WITH_AES_256_GCM_SHA384;
    `ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256;
    `ECDHE_ECDSA_WITH_AES_128_GCM_SHA256;
    `ECDHE_ECDSA_WITH_AES_256_GCM_SHA384;
    `ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256;
  ]

let policy_version = (`TLS_1_2, `TLS_1_2)
let client_alpn = [ "h2"; "http/1.1" ]

let string_of_endpoint_class = function
  | Otlp_collector -> "otlp_collector"
  | Llm_provider -> "llm_provider"
  | Cdn_reference -> "cdn_reference"

let string_of_tls_version = function
  | `TLS_1_0 -> "tls10"
  | `TLS_1_1 -> "tls11"
  | `TLS_1_2 -> "tls12"
  | `TLS_1_3 -> "tls13"

let pp_cipher cipher = Format.asprintf "%a" Tls.Ciphersuite.pp_ciphersuite cipher

let host_exn name =
  match Result.bind (Domain_name.of_string name) Domain_name.host with
  | Ok host -> host
  | Error (`Msg msg) -> failwith msg

let ca_authenticator () =
  match Ca_certs.authenticator () with
  | Ok authenticator -> authenticator
  | Error (`Msg msg) -> failwith msg

let truncate max_len value =
  if String.length value <= max_len then value
  else String.sub value 0 max_len ^ "..."

let normalize_error exn = truncate 260 (Printexc.to_string exn)

let connect_addr net target addr =
  Eio.Switch.run @@ fun sw ->
  let raw_flow = Eio.Net.connect ~sw net addr in
  let tls_flow =
    Tls_eio.client_of_flow
      (Tls.Config.client
         ~authenticator:(ca_authenticator ())
         ~alpn_protocols:client_alpn
         ~version:policy_version
         ~ciphers:narrowed_ciphers
         ())
      ~host:(host_exn target.host)
      raw_flow
  in
  let epoch =
    match Tls_eio.epoch tls_flow with
    | Ok epoch -> epoch
    | Error () -> failwith "TLS epoch unavailable"
  in
  let outcome =
    Handshake_ok
      {
        version = string_of_tls_version epoch.Tls.Core.protocol_version;
        alpn = epoch.Tls.Core.alpn_protocol;
        cipher = pp_cipher epoch.Tls.Core.ciphersuite;
      }
  in
  Eio.Resource.close tls_flow;
  outcome

let rec first_success net target errors = function
  | [] -> Handshake_error (String.concat " | " (List.rev errors))
  | addr :: rest -> (
      match connect_addr net target addr with
      | Handshake_ok _ as ok -> ok
      | Handshake_error _ as err -> err
      | exception exn ->
          let detail = normalize_error exn in
          first_success net target (detail :: errors) rest)

let connect_target env target =
  Mirage_crypto_rng_eio.run (module Mirage_crypto_rng.Fortuna) env @@ fun () ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  match
    Eio.Time.with_timeout clock 12.0 (fun () ->
        let addrs = Eio.Net.getaddrinfo_stream net target.host ~service:target.service in
        match addrs with
        | [] -> Ok (Handshake_error "no resolved stream addresses")
        | addrs -> Ok (first_success net target [] addrs))
  with
  | Ok outcome -> outcome
  | Error `Timeout -> Handshake_error "timeout"
  | exception exn -> Handshake_error (normalize_error exn)

let targets =
  [
    {
      name = "honeycomb_otlp";
      endpoint_class = Otlp_collector;
      url = "https://api.honeycomb.io/v1/traces";
      host = "api.honeycomb.io";
      service = "443";
      rationale = "Honeycomb public OTLP/HTTPS ingest endpoint.";
    };
    {
      name = "datadog_otlp_us1";
      endpoint_class = Otlp_collector;
      url = "https://otlp.datadoghq.com/v1/traces";
      host = "otlp.datadoghq.com";
      service = "443";
      rationale = "Datadog public OTLP/HTTPS intake endpoint for the US1 site.";
    };
    {
      name = "grafana_cloud_otlp_us_central";
      endpoint_class = Otlp_collector;
      url = "https://otlp-gateway-prod-us-central-0.grafana.net/otlp/v1/traces";
      host = "otlp-gateway-prod-us-central-0.grafana.net";
      service = "443";
      rationale = "Grafana Cloud OTLP gateway shape documented for region-specific stacks.";
    };
    {
      name = "logzio_jaeger_us";
      endpoint_class = Otlp_collector;
      url = "https://listener.logz.io:8071/api/traces";
      host = "listener.logz.io";
      service = "8071";
      rationale = "Logz.io cloud Jaeger HTTPS listener, covering the Jaeger-cloud class.";
    };
    {
      name = "otel_reference_demo_frontdoor";
      endpoint_class = Otlp_collector;
      url = "https://opentelemetry.io/docs/demo/";
      host = "opentelemetry.io";
      service = "443";
      rationale = "OpenTelemetry demo public front door; the demo collector itself is compose-internal, so this is a reachability caveat rather than collector proof.";
    };
    {
      name = "openai_api";
      endpoint_class = Llm_provider;
      url = "https://api.openai.com/v1/responses";
      host = "api.openai.com";
      service = "443";
      rationale = "OpenAI public HTTPS API endpoint.";
    };
    {
      name = "anthropic_api";
      endpoint_class = Llm_provider;
      url = "https://api.anthropic.com/v1/messages";
      host = "api.anthropic.com";
      service = "443";
      rationale = "Anthropic public HTTPS API endpoint.";
    };
    {
      name = "google_ai_generative_language";
      endpoint_class = Llm_provider;
      url = "https://generativelanguage.googleapis.com/v1beta/models";
      host = "generativelanguage.googleapis.com";
      service = "443";
      rationale = "Google AI Generative Language public HTTPS API endpoint.";
    };
    {
      name = "azure_ai_inference";
      endpoint_class = Llm_provider;
      url = "https://models.inference.ai.azure.com";
      host = "models.inference.ai.azure.com";
      service = "443";
      rationale = "Concrete Azure AI inference endpoint; Azure OpenAI resource hosts are tenant-specific.";
    };
    {
      name = "cohere_api";
      endpoint_class = Llm_provider;
      url = "https://api.cohere.com/v2/chat";
      host = "api.cohere.com";
      service = "443";
      rationale = "Cohere public HTTPS API endpoint.";
    };
    {
      name = "mistral_api";
      endpoint_class = Llm_provider;
      url = "https://api.mistral.ai/v1/chat/completions";
      host = "api.mistral.ai";
      service = "443";
      rationale = "Mistral public HTTPS API endpoint.";
    };
    {
      name = "cloudflare_api";
      endpoint_class = Cdn_reference;
      url = "https://api.cloudflare.com/client/v4/user/tokens/verify";
      host = "api.cloudflare.com";
      service = "443";
      rationale = "Cloudflare-fronted public API reference.";
    };
    {
      name = "aws_sts";
      endpoint_class = Cdn_reference;
      url = "https://sts.amazonaws.com/";
      host = "sts.amazonaws.com";
      service = "443";
      rationale = "AWS-fronted public API reference.";
    };
  ]

let print_target target =
  Printf.printf
    "target name=%s class=%s url=%s host=%s rationale=%S\n%!"
    target.name
    (string_of_endpoint_class target.endpoint_class)
    target.url target.host target.rationale

let print_outcome target = function
  | Handshake_ok { version; alpn; cipher } ->
      Printf.printf
        "h_s3_reach name=%s class=%s host=%s outcome=ok version=%s alpn=%s cipher=%S policy=tls12_ecdhe_aead_only\n%!"
        target.name
        (string_of_endpoint_class target.endpoint_class)
        target.host version
        (Option.value ~default:"<none>" alpn)
        cipher
  | Handshake_error detail ->
      Printf.printf
        "h_s3_reach name=%s class=%s host=%s outcome=error detail=%S policy=tls12_ecdhe_aead_only\n%!"
        target.name
        (string_of_endpoint_class target.endpoint_class)
        target.host detail

let () =
  Eio_main.run @@ fun env ->
  List.iter print_target targets;
  let failures =
    List.filter_map
      (fun target ->
        let outcome = connect_target env target in
        print_outcome target outcome;
        match outcome with
        | Handshake_ok { version = "tls12"; _ } -> None
        | Handshake_ok _ | Handshake_error _ -> Some target.name)
      targets
  in
  match failures with
  | [] ->
      Printf.printf
        "h_s3_reach_summary verdict=PASS targets=%d failed=<none> policy=tls12_ecdhe_aead_only\n%!"
        (List.length targets)
  | failures ->
      Printf.printf
        "h_s3_reach_summary verdict=FAIL targets=%d failed=%s policy=tls12_ecdhe_aead_only\n%!"
        (List.length targets) (String.concat "," failures)
