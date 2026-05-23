# S1 Reach Probe

## Question

Can the public eta-http h1 client reach the same 13 endpoint classes that the
ADR 0002 TLS reach lab covered?

## Implementation

- Probe executable: `scratch/eta_http_v1/probes/reach_13.ml`.
- Path under test: `Eta_http.Client.make_h1` -> `Eta_http.request`.
- Method: `HEAD`, so the probe exercises DNS, TCP, TLS, h1 request writing,
  h1 response parsing, status/header handling, body release, and pool shutdown
  without depending on S3 chunked/gzip body support.
- TLS posture: ADR 0002 TLS 1.2 ECDHE-AEAD policy, with h1 ALPN forced to
  `http/1.1`.

## Evidence

```sh
nix develop -c dune exec scratch/eta_http_v1/probes/reach_13.exe
```

Observed:

```text
eta_http_s1_reach name=honeycomb_otlp class=otlp_collector outcome=ok status=405 body_bytes=0 protocol=h1 policy=tls12_ecdhe_aead_only
eta_http_s1_reach name=datadog_otlp_us1 class=otlp_collector outcome=ok status=405 body_bytes=0 protocol=h1 policy=tls12_ecdhe_aead_only
eta_http_s1_reach name=grafana_cloud_otlp_us_central class=otlp_collector outcome=ok status=405 body_bytes=0 protocol=h1 policy=tls12_ecdhe_aead_only
eta_http_s1_reach name=logzio_jaeger_us class=otlp_collector outcome=ok status=405 body_bytes=0 protocol=h1 policy=tls12_ecdhe_aead_only
eta_http_s1_reach name=otel_reference_demo_frontdoor class=otlp_collector outcome=ok status=200 body_bytes=0 protocol=h1 policy=tls12_ecdhe_aead_only
eta_http_s1_reach name=openai_api class=llm_provider outcome=ok status=401 body_bytes=0 protocol=h1 policy=tls12_ecdhe_aead_only
eta_http_s1_reach name=anthropic_api class=llm_provider outcome=ok status=405 body_bytes=0 protocol=h1 policy=tls12_ecdhe_aead_only
eta_http_s1_reach name=google_ai_generative_language class=llm_provider outcome=ok status=404 body_bytes=0 protocol=h1 policy=tls12_ecdhe_aead_only
eta_http_s1_reach name=azure_ai_inference class=llm_provider outcome=ok status=401 body_bytes=0 protocol=h1 policy=tls12_ecdhe_aead_only
eta_http_s1_reach name=cohere_api class=llm_provider outcome=ok status=401 body_bytes=0 protocol=h1 policy=tls12_ecdhe_aead_only
eta_http_s1_reach name=mistral_api class=llm_provider outcome=ok status=401 body_bytes=0 protocol=h1 policy=tls12_ecdhe_aead_only
eta_http_s1_reach name=cloudflare_api class=cdn_reference outcome=ok status=400 body_bytes=0 protocol=h1 policy=tls12_ecdhe_aead_only
eta_http_s1_reach name=aws_sts class=cdn_reference outcome=ok status=302 body_bytes=0 protocol=h1 policy=tls12_ecdhe_aead_only
eta_http_s1_reach_summary verdict=PASS targets=13 failed=<none> protocol=h1 policy=tls12_ecdhe_aead_only
```

## Verdict

PASS for the S1 reach gate.

This proves endpoint reachability through eta-http's public h1 path. It does
not close S2 ALPN/h2 behavior or S3 body decoding.

## Caveats

- The probe accepts any HTTP status as reachability evidence. Several ingestion
  endpoints return `405` for `HEAD`, which still proves DNS, TLS, h1 request,
  and response parsing.
- Azure OpenAI exact resource-host coverage remains a reopener because those
  hosts are tenant-specific.
