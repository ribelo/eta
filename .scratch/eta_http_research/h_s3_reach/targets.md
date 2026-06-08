# H-S3-Reach Targets

Question: do intended eta-http v1 endpoint classes accept a TLS 1.2 client
hello under ADR 0002's narrowed ECDHE-AEAD policy?

The probe sends no application data. It resolves each host, attempts a TLS
handshake on port 443, and records negotiated TLS version, ALPN, and cipher.

| Name | Class | URL | Rationale |
| --- | --- | --- | --- |
| honeycomb_otlp | OTLP/HTTPS collector | https://api.honeycomb.io/v1/traces | Honeycomb public OTLP/HTTPS ingest endpoint. |
| datadog_otlp_us1 | OTLP/HTTPS collector | https://otlp.datadoghq.com/v1/traces | Datadog public OTLP/HTTPS intake endpoint for the US1 site. |
| grafana_cloud_otlp_us_central | OTLP/HTTPS collector | https://otlp-gateway-prod-us-central-0.grafana.net/otlp/v1/traces | Grafana Cloud OTLP gateway shape documented for region-specific stacks. |
| logzio_jaeger_us | OTLP/HTTPS collector | https://listener.logz.io:8071/api/traces | Logz.io cloud Jaeger HTTPS listener, covering the Jaeger-cloud class. |
| otel_reference_demo_frontdoor | OTLP/HTTPS collector | https://opentelemetry.io/docs/demo/ | OpenTelemetry demo public front door; the demo collector itself is compose-internal, so this is a reachability caveat rather than collector proof. |
| openai_api | LLM provider | https://api.openai.com/v1/responses | OpenAI public HTTPS API endpoint. |
| anthropic_api | LLM provider | https://api.anthropic.com/v1/messages | Anthropic public HTTPS API endpoint. |
| google_ai_generative_language | LLM provider | https://generativelanguage.googleapis.com/v1beta/models | Google AI Generative Language public HTTPS API endpoint. |
| azure_ai_inference | LLM provider | https://models.inference.ai.azure.com | Concrete Azure AI inference endpoint; Azure OpenAI resource hosts are tenant-specific. |
| cohere_api | LLM provider | https://api.cohere.com/v2/chat | Cohere public HTTPS API endpoint. |
| mistral_api | LLM provider | https://api.mistral.ai/v1/chat/completions | Mistral public HTTPS API endpoint. |
| cloudflare_api | CDN-fronted reference | https://api.cloudflare.com/client/v4/user/tokens/verify | Cloudflare-fronted public API reference. |
| aws_sts | AWS-fronted reference | https://sts.amazonaws.com/ | AWS-fronted public API reference. |

Azure OpenAI caveat: the documented Azure OpenAI data-plane host is
tenant/resource-specific: https://{resource-name}.openai.azure.com. This lab
uses the concrete Azure AI inference endpoint because it is publicly resolvable
without a tenant-owned resource. A tenant-specific Azure OpenAI resource remains
a reopener target before claiming coverage for that exact service.

OpenTelemetry demo caveat: the reference collector in
open-telemetry/opentelemetry-demo is configured as a compose-internal service
through environment variables. No public collector DNS endpoint was found. The
opentelemetry.io target proves the public reference host accepts the policy,
not that a hosted demo collector exists.
