(* Scratch-only S1 reach probe through the public eta-http h1 path. *)

type endpoint_class =
  | Otlp_collector
  | Llm_provider
  | Cdn_reference

type target = {
  name : string;
  endpoint_class : endpoint_class;
  url : string;
  rationale : string;
}

let string_of_endpoint_class = function
  | Otlp_collector -> "otlp_collector"
  | Llm_provider -> "llm_provider"
  | Cdn_reference -> "cdn_reference"

let targets =
  [
    {
      name = "honeycomb_otlp";
      endpoint_class = Otlp_collector;
      url = "https://api.honeycomb.io/v1/traces";
      rationale = "Honeycomb public OTLP/HTTPS ingest endpoint.";
    };
    {
      name = "datadog_otlp_us1";
      endpoint_class = Otlp_collector;
      url = "https://otlp.datadoghq.com/v1/traces";
      rationale = "Datadog public OTLP/HTTPS intake endpoint for the US1 site.";
    };
    {
      name = "grafana_cloud_otlp_us_central";
      endpoint_class = Otlp_collector;
      url = "https://otlp-gateway-prod-us-central-0.grafana.net/otlp/v1/traces";
      rationale =
        "Grafana Cloud OTLP gateway shape documented for region-specific stacks.";
    };
    {
      name = "logzio_jaeger_us";
      endpoint_class = Otlp_collector;
      url = "https://listener.logz.io:8071/api/traces";
      rationale =
        "Logz.io cloud Jaeger HTTPS listener, covering the Jaeger-cloud class.";
    };
    {
      name = "otel_reference_demo_frontdoor";
      endpoint_class = Otlp_collector;
      url = "https://opentelemetry.io/docs/demo/";
      rationale =
        "OpenTelemetry demo public front door; the demo collector itself is compose-internal.";
    };
    {
      name = "openai_api";
      endpoint_class = Llm_provider;
      url = "https://api.openai.com/v1/responses";
      rationale = "OpenAI public HTTPS API endpoint.";
    };
    {
      name = "anthropic_api";
      endpoint_class = Llm_provider;
      url = "https://api.anthropic.com/v1/messages";
      rationale = "Anthropic public HTTPS API endpoint.";
    };
    {
      name = "google_ai_generative_language";
      endpoint_class = Llm_provider;
      url = "https://generativelanguage.googleapis.com/v1beta/models";
      rationale = "Google AI Generative Language public HTTPS API endpoint.";
    };
    {
      name = "azure_ai_inference";
      endpoint_class = Llm_provider;
      url = "https://models.inference.ai.azure.com";
      rationale =
        "Concrete Azure AI inference endpoint; Azure OpenAI resource hosts are tenant-specific.";
    };
    {
      name = "cohere_api";
      endpoint_class = Llm_provider;
      url = "https://api.cohere.com/v2/chat";
      rationale = "Cohere public HTTPS API endpoint.";
    };
    {
      name = "mistral_api";
      endpoint_class = Llm_provider;
      url = "https://api.mistral.ai/v1/chat/completions";
      rationale = "Mistral public HTTPS API endpoint.";
    };
    {
      name = "cloudflare_api";
      endpoint_class = Cdn_reference;
      url = "https://api.cloudflare.com/client/v4/user/tokens/verify";
      rationale = "Cloudflare-fronted public API reference.";
    };
    {
      name = "aws_sts";
      endpoint_class = Cdn_reference;
      url = "https://sts.amazonaws.com/";
      rationale = "AWS-fronted public API reference.";
    };
  ]

let authenticator () =
  match Ca_certs.authenticator () with
  | Ok authenticator -> authenticator
  | Error (`Msg msg) -> failwith msg

let request_target rt client target =
  let request =
    Eta_http.Request.make ~headers:[ ("User-Agent", "eta-http-s1-reach") ]
      "HEAD" target.url
  in
  let timeout_error =
    Eta_http.Error.make ~method_:"HEAD" ~uri:target.url
      (Total_request_timeout { timeout_ms = Some 15_000 })
  in
  let request_effect =
    Eta_http.request client request
    |> Eta.Effect.timeout_as (Eta.Duration.seconds 15) ~on_timeout:timeout_error
  in
  match Eta.Runtime.run rt request_effect with
  | Eta.Exit.Error cause ->
      Error (Format.asprintf "%a" (Eta.Cause.pp Eta_http.Error.pp) cause)
  | Eta.Exit.Ok response -> (
      match Eta.Runtime.run rt (Eta_http.Body.Stream.read_all response.body) with
      | Eta.Exit.Error cause ->
          Error
            (Format.asprintf "body read failed: %a"
               (Eta.Cause.pp Eta_http.Error.pp)
               cause)
      | Eta.Exit.Ok body -> Ok (response.status, Bytes.length body))

let print_target target =
  Printf.printf "target name=%s class=%s url=%s rationale=%S\n%!" target.name
    (string_of_endpoint_class target.endpoint_class)
    target.url target.rationale

let print_result target = function
  | Ok (status, body_bytes) ->
      Printf.printf
        "eta_http_s1_reach name=%s class=%s outcome=ok status=%d body_bytes=%d protocol=h1 policy=tls12_ecdhe_aead_only\n%!"
        target.name
        (string_of_endpoint_class target.endpoint_class)
        status body_bytes
  | Error detail ->
      Printf.printf
        "eta_http_s1_reach name=%s class=%s outcome=error detail=%S protocol=h1 policy=tls12_ecdhe_aead_only\n%!"
        target.name
        (string_of_endpoint_class target.endpoint_class)
        detail

let run env =
  Mirage_crypto_rng_eio.run (module Mirage_crypto_rng.Fortuna) env @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let client =
    Eta_http.Client.make_h1 ~sw ~net:(Eio.Stdenv.net env)
      ~authenticator:(authenticator ()) ()
  in
  List.iter print_target targets;
  let failures =
    List.filter_map
      (fun target ->
        let result = request_target rt client target in
        print_result target result;
        match result with Ok _ -> None | Error _ -> Some target.name)
      targets
  in
  ignore (Eta.Runtime.run rt (Eta_http.Client.shutdown client));
  match failures with
  | [] ->
      Printf.printf
        "eta_http_s1_reach_summary verdict=PASS targets=%d failed=<none> protocol=h1 policy=tls12_ecdhe_aead_only\n%!"
        (List.length targets)
  | failures ->
      Printf.printf
        "eta_http_s1_reach_summary verdict=FAIL targets=%d failed=%s protocol=h1 policy=tls12_ecdhe_aead_only\n%!"
        (List.length targets) (String.concat "," failures);
      exit 1

let () = Eio_main.run run
