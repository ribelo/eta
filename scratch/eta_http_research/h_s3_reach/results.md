# H-S3-Reach Results

Status: PASS-WITH-CAVEATS.

## Question

Does every intended eta-http v1 endpoint class accept a TLS 1.2 client hello
using the ADR 0002 Option 2 policy: TLS 1.2 only, ECDHE RSA/ECDSA AEAD ciphers
only, no DHE_RSA suites, and no live revocation fetching?

## Command

~~~text
nix develop -c dune exec scratch/eta_http_research/h_s3_reach/probe.exe
~~~

## Policy Under Test

- TLS version range: TLS 1.2 to TLS 1.2.
- Ciphers:
  - ECDHE_RSA_WITH_AES_128_GCM_SHA256
  - ECDHE_RSA_WITH_AES_256_GCM_SHA384
  - ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
  - ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
  - ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
  - ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256
- ALPN offered: h2, then http/1.1.
- Revocation: no live fetching; caller-owned per ADR 0001.
- Application data: none sent.

## Transcript

~~~text
target name=honeycomb_otlp class=otlp_collector url=https://api.honeycomb.io/v1/traces host=api.honeycomb.io rationale="Honeycomb public OTLP/HTTPS ingest endpoint."
target name=datadog_otlp_us1 class=otlp_collector url=https://otlp.datadoghq.com/v1/traces host=otlp.datadoghq.com rationale="Datadog public OTLP/HTTPS intake endpoint for the US1 site."
target name=grafana_cloud_otlp_us_central class=otlp_collector url=https://otlp-gateway-prod-us-central-0.grafana.net/otlp/v1/traces host=otlp-gateway-prod-us-central-0.grafana.net rationale="Grafana Cloud OTLP gateway shape documented for region-specific stacks."
target name=logzio_jaeger_us class=otlp_collector url=https://listener.logz.io:8071/api/traces host=listener.logz.io rationale="Logz.io cloud Jaeger HTTPS listener, covering the Jaeger-cloud class."
target name=otel_reference_demo_frontdoor class=otlp_collector url=https://opentelemetry.io/docs/demo/ host=opentelemetry.io rationale="OpenTelemetry demo public front door; the demo collector itself is compose-internal, so this is a reachability caveat rather than collector proof."
target name=openai_api class=llm_provider url=https://api.openai.com/v1/responses host=api.openai.com rationale="OpenAI public HTTPS API endpoint."
target name=anthropic_api class=llm_provider url=https://api.anthropic.com/v1/messages host=api.anthropic.com rationale="Anthropic public HTTPS API endpoint."
target name=google_ai_generative_language class=llm_provider url=https://generativelanguage.googleapis.com/v1beta/models host=generativelanguage.googleapis.com rationale="Google AI Generative Language public HTTPS API endpoint."
target name=azure_ai_inference class=llm_provider url=https://models.inference.ai.azure.com host=models.inference.ai.azure.com rationale="Concrete Azure AI inference endpoint; Azure OpenAI resource hosts are tenant-specific."
target name=cohere_api class=llm_provider url=https://api.cohere.com/v2/chat host=api.cohere.com rationale="Cohere public HTTPS API endpoint."
target name=mistral_api class=llm_provider url=https://api.mistral.ai/v1/chat/completions host=api.mistral.ai rationale="Mistral public HTTPS API endpoint."
target name=cloudflare_api class=cdn_reference url=https://api.cloudflare.com/client/v4/user/tokens/verify host=api.cloudflare.com rationale="Cloudflare-fronted public API reference."
target name=aws_sts class=cdn_reference url=https://sts.amazonaws.com/ host=sts.amazonaws.com rationale="AWS-fronted public API reference."
h_s3_reach name=honeycomb_otlp class=otlp_collector host=api.honeycomb.io outcome=ok version=tls12 alpn=h2 cipher="ECDHE RSA AEAD AES128 GCM" policy=tls12_ecdhe_aead_only
h_s3_reach name=datadog_otlp_us1 class=otlp_collector host=otlp.datadoghq.com outcome=ok version=tls12 alpn=h2 cipher="ECDHE RSA AEAD CHACHA20 POLY1305" policy=tls12_ecdhe_aead_only
h_s3_reach name=grafana_cloud_otlp_us_central class=otlp_collector host=otlp-gateway-prod-us-central-0.grafana.net outcome=ok version=tls12 alpn=h2 cipher="ECDHE RSA AEAD AES128 GCM" policy=tls12_ecdhe_aead_only
h_s3_reach name=logzio_jaeger_us class=otlp_collector host=listener.logz.io outcome=ok version=tls12 alpn=http/1.1 cipher="ECDHE RSA AEAD AES256 GCM" policy=tls12_ecdhe_aead_only
h_s3_reach name=otel_reference_demo_frontdoor class=otlp_collector host=opentelemetry.io outcome=ok version=tls12 alpn=h2 cipher="ECDHE ECDSA AEAD AES128 GCM" policy=tls12_ecdhe_aead_only
h_s3_reach name=openai_api class=llm_provider host=api.openai.com outcome=ok version=tls12 alpn=h2 cipher="ECDHE ECDSA AEAD AES128 GCM" policy=tls12_ecdhe_aead_only
h_s3_reach name=anthropic_api class=llm_provider host=api.anthropic.com outcome=ok version=tls12 alpn=h2 cipher="ECDHE ECDSA AEAD AES128 GCM" policy=tls12_ecdhe_aead_only
h_s3_reach name=google_ai_generative_language class=llm_provider host=generativelanguage.googleapis.com outcome=ok version=tls12 alpn=h2 cipher="ECDHE ECDSA AEAD AES256 GCM" policy=tls12_ecdhe_aead_only
h_s3_reach name=azure_ai_inference class=llm_provider host=models.inference.ai.azure.com outcome=ok version=tls12 alpn=h2 cipher="ECDHE RSA AEAD AES128 GCM" policy=tls12_ecdhe_aead_only
h_s3_reach name=cohere_api class=llm_provider host=api.cohere.com outcome=ok version=tls12 alpn=h2 cipher="ECDHE RSA AEAD AES128 GCM" policy=tls12_ecdhe_aead_only
h_s3_reach name=mistral_api class=llm_provider host=api.mistral.ai outcome=ok version=tls12 alpn=h2 cipher="ECDHE ECDSA AEAD AES128 GCM" policy=tls12_ecdhe_aead_only
h_s3_reach name=cloudflare_api class=cdn_reference host=api.cloudflare.com outcome=ok version=tls12 alpn=h2 cipher="ECDHE ECDSA AEAD AES128 GCM" policy=tls12_ecdhe_aead_only
h_s3_reach name=aws_sts class=cdn_reference host=sts.amazonaws.com outcome=ok version=tls12 alpn=http/1.1 cipher="ECDHE RSA AEAD AES128 GCM" policy=tls12_ecdhe_aead_only
h_s3_reach_summary verdict=PASS targets=13 failed=<none> policy=tls12_ecdhe_aead_only
~~~

## Target Correction Notes

The first draft used two weak targets:

- jaeger-collector.tempo-prod-us-central-0.grafana.net returned TLS handshake
  failure under both TLS 1.2 and TLS 1.3, so it was not evidence of a TLS
  1.3-only requirement. It was replaced with Logz.io's concrete Jaeger HTTPS
  listener on listener.logz.io:8071.
- collector.demo.opentelemetry.io did not resolve. The OpenTelemetry demo
  collector is configured as a compose-internal service. The public
  opentelemetry.io demo/docs front door was retained as a reference-host
  reachability check, but it is not proof of a public hosted collector.

## Verdict

All 13 concrete targets in the corrected matrix accepted the ADR 0002 TLS 1.2
ECDHE-AEAD policy. No target produced protocol_version_alert, TLS 1.3-required
evidence, or narrowed-cipher refusal.

Result: Option 2 stands with caveats.

## Caveats

- Azure OpenAI's documented data-plane host is tenant/resource-specific:
  https://{resource-name}.openai.azure.com. This lab used the concrete Azure AI
  inference endpoint. A tenant-specific Azure OpenAI resource remains a reopener
  target.
- The OpenTelemetry demo collector is not exposed as a public collector
  endpoint. This lab proves the public reference host accepts the policy, not a
  hosted demo collector.

## Reopener

Any future intended v1 consumer endpoint that fails this probe with a TLS-layer
version or cipher-policy refusal reopens ADR 0002 and promotes Option 3 or a
digestif/OxCaml patch track from deferred to active.
